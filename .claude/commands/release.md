# Release

Ship a stable cmux release built by CI: bump version, update changelog, open a PR, merge, tag, then GitHub Actions builds, signs, and publishes.

`skills/cmux-release/SKILL.md` owns the version-bump, pretag-guard, and tag mechanics plus the Apple signing secrets. This file owns the shared changelog and contributor procedure that `/release-nightly` and `/release-local` also use, and the PR-and-CI build path.

## Shared prep (all three release commands)

1. **Pick the version.** Read `MARKETING_VERSION` from `cmux.xcodeproj/project.pbxproj`. Bump minor unless the user says otherwise (0.12.0 to 0.13.0).

2. **Gather the changelog lines since the last stable tag.** Every PR carries its release-note line in the `## Changelog` section of its description (one `Added`/`Changed`/`Fixed`/`Removed` line, or `none`). Take the PR numbers from main's first-parent history, then fetch every PR in one GraphQL query:

   ```bash
   # A shallow clone stops history early and silently drops PRs from the range.
   if [ "$(git rev-parse --is-shallow-repository)" = true ]; then git fetch --unshallow --tags origin; fi
   TAG=$(git describe --tags --abbrev=0 --match 'v[0-9]*')   # plain describe finds `nightly`
   git log --first-parent --format=%s "$TAG"..HEAD \
     | sed -nE 's/^Merge pull request #([0-9]+) .*/\1/p; s/.*\(#([0-9]+)\)$/\1/p' | sort -un > /tmp/release-prs.txt
   {
     echo 'query { repository(owner: "manaflow-ai", name: "cmux") {'
     sed 's/.*/  n&: issueOrPullRequest(number: &) { ... on PullRequest { ...P } }/' /tmp/release-prs.txt
     echo '} } fragment P on PullRequest { number title body url author { __typename login }
       mergeCommit { oid } closingIssuesReferences(first: 10) { nodes { author { __typename login } } } }'
   } > /tmp/release-query.graphql
   gh api graphql -F query=@/tmp/release-query.graphql > /tmp/release-raw.json \
     || echo "GraphQL query failed; read /tmp/release-raw.json before going on"
   jq -c '.data.repository[] | select(.number != null)' /tmp/release-raw.json > /tmp/release-prs.jsonl
   git log --first-parent --format='%H%n%B%n@@end@@' "$TAG"..HEAD > /tmp/release-log.txt
   jq -r -s --rawfile log /tmp/release-log.txt \
     -f skills/cmux-release/references/changelog-lines.jq /tmp/release-prs.jsonl > /tmp/release-lines.tsv
   ```

   Check that `/tmp/release-prs.jsonl` has about as many lines as `/tmp/release-prs.txt`; the gap is numbers in commit titles that are issues, not PRs. The query is one request (1,257 PRs took 8 seconds) and reads from a file, so its size isn't limited by the shell's argument list. If it times out, run it on each half of `/tmp/release-prs.txt` and concatenate the output; don't fall back to one `gh` call per PR. The search API is not a substitute: it stops at 1,000 results, which ten days of merges exceed.

   Each row of `/tmp/release-lines.tsv` is `status`, `#number`, `url`, `author`, `credit`, `line`:

   - `entry`: every line of the PR's Changelog section starts with `Added`, `Changed`, `Fixed` or `Removed`. File each line under the category its prefix names (drop the prefix) and append the PR link and credit. Several lines arrive joined with a literal `\n`; each becomes its own bullet.
   - `check-line`: the section has a line without a category prefix. Rewrite it into a user-facing line, or drop it if nothing is user-visible, and list the PR for the human.
   - `check-title`: the PR has no Changelog section, so `line` is its title. Write a user-facing line from the PR if it is user-visible under the guidelines below, or drop it, and list every such PR for the human to check before the release PR merges.
   - `skip-none`, `skip-reverted`, `skip-revert`: leave out. `skip-reverted` is a PR undone later in the range by a revert that was not itself reverted, so it never shipped; a revert of a revert (a reapply) leaves the original PR live. `skip-revert` is a revert or reapply whose targets are all in this range, so the targets' own rows already account for it.
   - `revert-of-X`: a revert or reapply of `X` (a PR number or commit SHA) that shipped in an earlier release. The revert is itself user-visible: write a line for it (a reverted feature is `Removed`, a reverted fix is `Fixed` or `Changed`) and flag it for the human. `revert-of-?` means the target couldn't be found from a `Reverts #N` line in the body, the title or a `This reverts commit` line on main. A revert PR landed as a merge commit with no `Reverts #N` line always ends up here, because its `git revert` commit sits on the side branch: open the PR, find what it reverts, and treat it as `skip-revert` if that is in this range or as `revert-of-X` if it shipped earlier.

   Also list for the human any first-parent commit without a PR number (`git log --first-parent --format='%h %s' "$TAG"..HEAD | grep -vE '\(#[0-9]+\)$| Merge pull request #'`); the query can't see them. Credit follows [Contributor credits](#contributor-credits): the `credit` column already thanks the PR author and the reporters of the issues the PR closes, leaving out the core team, bots and the PR's own author as reporter. If nothing is user-facing, ask the user whether to release anyway.

3. **Update `CHANGELOG.md`.** Add a section at the top with the new version and today's date, built from step 2, with inline contributor credit and the contributor summary (the `author` of every PR that got a line, plus each credited reporter, leaving out bot accounts such as `[bot]` logins and `chatmux-connections`). Then fold any entries under `## Unreleased` into that section (they predate the Changelog section in PR descriptions): move each into its category, drop any that duplicate a step 2 line for the same PR, and remove the emptied `## Unreleased` heading. The docs changelog page renders from `CHANGELOG.md`. Its headline cards live in `web/app/[locale]/(landing)/docs/changelog/changelog-media.ts`: rename the `Unreleased` key there to the new version, or add an entry if there is none.

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

Per-entry attribution goes after each changelog bullet: `-- thanks @user!` for a PR author, `-- thanks @reporter for the report!` for an issue reporter who is not the PR author (`-- thanks @a and @b for the reports!` for several, and `-- thanks @user, and thanks @reporter for the report!` when both apply). `CHANGELOG.md` uses two hyphens, not an em dash. Core team (`lawrencecchen`, `austinywang`, `teamleaderleo`) work is the baseline and gets no per-entry callout, and bots get none.

Every release ends with a summary section listing all contributors alphabetically by handle, core team included and bots left out, each linked to their GitHub profile. The published GitHub Release body carries the same section.

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
