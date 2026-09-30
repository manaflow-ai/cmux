# Release

Ship a stable cmux release built by CI: bump version, update changelog, open a PR, merge, tag, then GitHub Actions builds, signs, and publishes.

`skills/cmux-release/SKILL.md` owns the version-bump, pretag-guard, and tag mechanics plus the Apple signing secrets. This file owns the shared changelog and contributor procedure that `/release-nightly` and `/release-local` also use, and the PR-and-CI build path.

## Shared prep (all three release commands)

1. **Pick the version.** Read `MARKETING_VERSION` from `cmux.xcodeproj/project.pbxproj`. Bump minor unless the user says otherwise (0.12.0 to 0.13.0).

2. **Gather the changelog lines since the last stable tag.** Every PR carries its release-note line in the `## Changelog` section of its description (one `Added`/`Changed`/`Fixed`/`Removed` line, or `none`). Take the PR numbers from main's first-parent history, then fetch every PR in one GraphQL query:

   ```bash
   TAG=$(git describe --tags --abbrev=0 --match 'v[0-9]*')   # plain describe finds `nightly`
   git log --first-parent --format=%s "$TAG"..HEAD \
     | sed -nE 's/^Merge pull request #([0-9]+) .*/\1/p; s/.*\(#([0-9]+)\)$/\1/p' | sort -un > /tmp/release-prs.txt
   q='query { repository(owner: "manaflow-ai", name: "cmux") {'
   for n in $(cat /tmp/release-prs.txt); do q+=" pr$n: pullRequest(number: $n) { ...P }"; done
   q+=' } } fragment P on PullRequest { number title body url authorAssociation author { login }
     mergeCommit { oid } closingIssuesReferences(first: 10) { nodes { authorAssociation author { login } } } }'
   gh api graphql -f query="$q" --jq '.data.repository[]' > /tmp/release-prs.jsonl
   git rev-list "$TAG"..HEAD > /tmp/release-range.txt
   git log --format=%B "$TAG"..HEAD | sed -nE 's/.*This reverts commit ([0-9a-f]{40}).*/\1/p' > /tmp/release-reverted.txt
   jq -r -s --rawfile range /tmp/release-range.txt --rawfile reverted /tmp/release-reverted.txt \
     -f skills/cmux-release/references/changelog-lines.jq /tmp/release-prs.jsonl > /tmp/release-lines.tsv
   ```

   The query is one request (about 1,200 PRs took 20 seconds). If it times out, run it on each half of `/tmp/release-prs.txt` and concatenate the output; don't fall back to one `gh` call per PR. The search API is not a substitute: it stops at 1,000 results, which ten days of merges exceed.

   Each row of `/tmp/release-lines.tsv` is `status`, `#number`, `url`, `credit`, `line`:

   - `entry`: use the line, filed under the category its prefix names (drop the prefix), with the PR link and credit appended.
   - `check-title`: the PR has no Changelog section, so `line` is its title. Write a user-facing line from the PR if it is user-visible under the guidelines below, or drop it, and list every such PR for the human to check before the release PR merges.
   - `skip-none`, `skip-reverted`: leave out. A PR reverted later in the same range never shipped.
   - `revert-of-N`: leave out when N is in this range. When N shipped in an earlier release, the revert is itself user-visible; write a line for it and flag it for the human.

   Also list for the human any first-parent commit without a PR number (`git log --first-parent --format='%h %s' "$TAG"..HEAD | grep -vE '\(#[0-9]+\)$| Merge pull request #'`); the query can't see them. Credit follows [Contributor credits](#contributor-credits): the `credit` column already names outside authors, or outside issue reporters on team PRs, from each PR's author association and closing issues. If nothing is user-facing, ask the user whether to release anyway.

3. **Update `CHANGELOG.md`.** Add a section at the top with the new version and today's date, built from step 2, with inline contributor credit and the contributor summary. Then fold any entries under `## Unreleased` into that section (they predate the Changelog section in PR descriptions): move each into its category, drop any that duplicate a step 2 line for the same PR, and remove the emptied `## Unreleased` heading. The docs changelog page renders from `CHANGELOG.md`, so there is no second changelog file to edit.

4. **Bump the version.** `./scripts/bump-version.sh` (minor by default) updates `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` everywhere in the Xcode project.

## CI-built release (this command)

5. **Branch, commit, push.** `git checkout -b release/vX.Y.Z`, stage `CHANGELOG.md` and `cmux.xcodeproj/project.pbxproj`, commit `Bump version to X.Y.Z`, then `git push -u origin release/vX.Y.Z`.

6. **PR and CI.** `gh pr create --title "Release vX.Y.Z" --body "...changelog summary..."` with the changelog entries in the body, then `gh pr checks --watch`. Fix failures and push until every check passes.

7. **Merge.** `gh pr merge --squash --delete-branch`, then `git checkout main && git pull`.

8. **Guard and tag.** `./scripts/release-pretag-guard.sh`, then `git tag vX.Y.Z && git push origin vX.Y.Z`. If the guard fails, run `./scripts/bump-version.sh`, commit the build-number bump, push and merge that change, then retry.

9. **Watch the release workflow.** `gh run watch --repo manaflow-ai/cmux`. Confirm the release at https://github.com/manaflow-ai/cmux/releases exists with `cmux-macos.dmg` attached.

10. **Verify the homebrew cask.** `update-homebrew.yml` triggers automatically once the release workflow finishes.

    ```bash
    gh run list --workflow=update-homebrew.yml --limit=1
    gh run watch --repo manaflow-ai/cmux <run-id>
    cd homebrew-cmux && git pull && grep version Casks/cmux.rb
    bash tests/test_homebrew_sha.sh
    ```

11. **Notify.** `say "cmux release complete"` on success, `say "cmux release failed"` on failure.

## Changelog guidelines

Include what a user can see, feel, or interact with: new features, noticeable bug fixes (crashes, UI glitches, wrong behavior), performance the user would feel, UI/UX changes, breaking changes and removals.

Exclude internal work: setup/build/reload scripts, CI and workflow changes, docs (README, CONTRIBUTING, CLAUDE.md), tests, refactors with no user-visible effect, and dependency bumps unless they fix a user-facing bug.

Write in present tense ("Add feature", not "Added feature"), grouped by Added, Changed, Fixed, Removed. Be concise and descriptive, describe what the user experiences rather than how it was implemented, and link the issue or PR when relevant.

## Contributor credits

Credit the people who made each release happen. This builds community and encourages contributions.

Per-entry attribution goes after each changelog bullet: `-- thanks @user!` for a PR author outside the team, `-- thanks @reporter for the report!` for an issue reporter outside the team who is not the PR author. `CHANGELOG.md` uses two hyphens, not an em dash. Team work (a PR author whose association is `MEMBER` or `OWNER`, including core team `lawrencecchen` and `austinywang`) is the baseline and gets no per-entry callout.

Every release ends with a summary section listing all contributors alphabetically by handle, core team included, each linked to their GitHub profile. The published GitHub Release body carries the same section.

```markdown
### Thanks to N contributors!

- [@user1](https://github.com/user1)
- [@user2](https://github.com/user2)
```

## Example changelog entry

```markdown
## [0.13.0] - 2025-01-30

### Added
- New keyboard shortcut for quick tab switching ([#42](https://github.com/manaflow-ai/cmux/pull/42)) -- thanks @contributor!

### Fixed
- Memory leak when closing split panes ([#38](https://github.com/manaflow-ai/cmux/pull/38)) -- thanks @fixer!
- Notification badges not clearing properly ([#35](https://github.com/manaflow-ai/cmux/pull/35)) -- thanks @reporter for the report!

### Changed
- Improved terminal rendering performance ([#40](https://github.com/manaflow-ai/cmux/pull/40))

### Thanks to 4 contributors!

- [@contributor](https://github.com/contributor)
- [@fixer](https://github.com/fixer)
- [@lawrencecchen](https://github.com/lawrencecchen)
- [@reporter](https://github.com/reporter)
```
