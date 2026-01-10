#!/bin/bash

# Fix dependabot PRs with failing "Check Licenses" step
# The reason this is required is because our CI requires third-party licenses
# to be updated when dependency bumps happen, but Dependabot does not do this.
# Usage: ./script/fix-dependabot-licenses.sh

set -e

echo "🔧 Running fix-dependabot-licenses - changes will be pushed"

if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "❌ Git working directory is not clean. Please commit or stash changes first."
    exit 1
fi

echo "📋 Fetching open dependabot PRs..."

# Get all open PRs by dependabot
dependabot_prs=$(gh pr list --author "app/dependabot" --state open --json number,title)

if [[ -z "$dependabot_prs" || "$dependabot_prs" == "[]" ]]; then
    echo "✅ No open dependabot PRs found"
    exit 0
fi

echo "🔍 Found $(echo "$dependabot_prs" | jq '. | length') dependabot PRs"

# Process each PR
echo "$dependabot_prs" | jq -r '.[] | "\(.number) \(.title)"' | while read -r pr_number pr_title; do
    echo ""
    echo "🔍 Checking PR #$pr_number: $pr_title"

    # Check if PR has failing lint step and get the first run ID
    lint_link=$(gh pr checks "$pr_number" --json name,state,workflow,link | jq -r '.[] | select(.workflow == "Lint" and .name == "lint" and .state == "FAILURE") | .link' | head -1)

    if [[ -n "$lint_link" ]]; then
        # Extract run ID from the link
        run_id=$(echo "$lint_link" | sed -E 's|.*/actions/runs/([0-9]+).*|\1|')
        echo "❌ Found failing lint step in PR #$pr_number (run ID: $run_id)"

        # Check if the specific "Check Licenses" step failed
        if ! gh run view "$run_id" 2>/dev/null | grep "X Check licenses" > /dev/null; then
            echo "✅ License check step is not failing in this run, skipping"
            continue
        fi

        echo "❌ Confirmed: 'Check Licenses' step failed in run $run_id"

        # Extract dependency name and version range from title for commit message
        # Example: "chore(deps): bump golang.org/x/term from 0.32.0 to 0.33.0 #11266"
        commitSuffix=$(echo "$pr_title" | sed -E 's/^chore\(deps\): //')

        if [[ -z "$commitSuffix" ]]; then
            echo "⚠️  Could not extract commit suffix from PR title: $pr_title"
            echo "⚠️  Skipping this PR"
            continue
        fi

        echo "📦 Commit Suffix: $commitSuffix"

        echo "🔧 Checking out PR #$pr_number..."
        gh pr checkout --force "$pr_number"

        echo "🔧 Running 'make licenses'..."
        make licenses

        # Check if there are any changes to commit
        if git diff --quiet && git diff --cached --quiet; then
            echo "✅ No license changes needed for PR #$pr_number"
            continue
        fi

        echo "🔧 Committing license changes..."
        git add third-party/ third-party-licenses*
        git commit -m "Fixed licenses for $commitSuffix"

        echo "🔧 Pushing changes..."
        git push
        echo "✅ Fixed licenses for PR #$pr_number"
    else
        echo "✅ PR #$pr_number has passing/pending lint checks"
    fi
done

echo ""
echo "✅ All applicable dependabot PRs have been processed."
