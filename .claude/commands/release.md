# Release

Ship a stable cmux release built by CI: bump version, update changelog, open a PR, merge, tag, then GitHub Actions builds, signs, and publishes.

`skills/cmux-release/SKILL.md` owns the version-bump, pretag-guard, and tag mechanics plus the Apple signing secrets. This file owns the shared changelog and contributor procedure that `/release-nightly` and `/release-local` also use, and the PR-and-CI build path.

## Shared prep (all three release commands)

1. **Pick the version.** Read `MARKETING_VERSION` from `cmux.xcodeproj/project.pbxproj`. Bump minor unless the user says otherwise (0.12.0 to 0.13.0).

2. **Gather changes and contributors since the last tag.**

   ```bash
   git describe --tags --abbrev=0
   git log --oneline <last-tag>..HEAD --no-merges
   gh pr view <N> --repo manaflow-ai/cmux --json author --jq '.author.login'
   gh issue view <N> --repo manaflow-ai/cmux --json author --jq '.author.login'
   ```

   Keep only end-user visible changes, categorize into Added, Changed, Fixed, Removed, and build a deduplicated list of contributor `@handle`s from PR authors and linked issue reporters. If nothing is user-facing, ask the user whether to release anyway.

3. **Update `CHANGELOG.md`.** Add a section at the top with the new version and today's date, written as user-facing descriptions rather than raw commit messages, with inline contributor credit. The docs changelog page renders from `CHANGELOG.md`, so there is no second changelog file to edit.

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

Per-entry attribution goes after each changelog bullet: `— thanks @user!` for a PR author, `— thanks @reporter for the report!` for an issue reporter who is not the PR author. Core team (`lawrencecchen`, `austinywang`) work is the baseline and gets no per-entry callout.

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
- New keyboard shortcut for quick tab switching ([#42](https://github.com/manaflow-ai/cmux/pull/42)) — thanks @contributor!

### Fixed
- Memory leak when closing split panes ([#38](https://github.com/manaflow-ai/cmux/pull/38)) — thanks @fixer!
- Notification badges not clearing properly ([#35](https://github.com/manaflow-ai/cmux/pull/35)) — thanks @reporter for the report!

### Changed
- Improved terminal rendering performance ([#40](https://github.com/manaflow-ai/cmux/pull/40))

### Thanks to 4 contributors!

- [@contributor](https://github.com/contributor)
- [@fixer](https://github.com/fixer)
- [@lawrencecchen](https://github.com/lawrencecchen)
- [@reporter](https://github.com/reporter)
```
