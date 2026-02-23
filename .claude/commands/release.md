# Release

Prepare a new release for cmux. This command updates the changelog, bumps the version, creates a PR, monitors CI, and then merges and tags.

## Steps

1. **Determine the new version number**
   - Get the current version from `GhosttyTabs.xcodeproj/project.pbxproj` (look for `MARKETING_VERSION`)
   - Bump the minor version unless the user specifies otherwise (e.g., 0.12.0 → 0.13.0)

2. **Create a release branch**
   - Create branch: `git checkout -b release/vX.Y.Z`

3. **Gather changes and contributors since the last release**
   - Find the most recent git tag: `git describe --tags --abbrev=0`
   - Get commits since that tag: `git log --oneline <last-tag>..HEAD --no-merges`
   - **Filter for end-user visible changes only** - ignore developer tooling, CI, docs, tests
   - Categorize changes into: Added, Changed, Fixed, Removed
   - **Collect contributors:** For each PR referenced in the commits, get the author:
     ```bash
     gh pr view <N> --repo manaflow-ai/cmux --json author --jq '.author.login'
     ```
   - Also check for linked issue reporters (the person who filed the bug):
     ```bash
     gh issue view <N> --repo manaflow-ai/cmux --json author --jq '.author.login'
     ```
   - Build a deduplicated list of all contributor `@handle`s for the release

4. **Update the changelog**
   - Add a new section at the top of `CHANGELOG.md` with the new version and today's date
   - **Only include changes that affect the end-user experience** - things users will see, feel, or interact with
   - Write clear, user-facing descriptions (not raw commit messages)
   - **Credit contributors inline** (see Contributor Credits below)
   - Also update `docs-site/content/docs/changelog.mdx` with the same content
   - If there are no user-facing changes, ask the user if they still want to release

5. **Bump the version in Xcode project**
   - Update all occurrences of `MARKETING_VERSION` in `GhosttyTabs.xcodeproj/project.pbxproj`
   - There are typically 4 occurrences (Debug/Release for main app and CLI)

6. **Commit and push the release branch**
   - Stage: `CHANGELOG.md`, `docs-site/content/docs/changelog.mdx`, `GhosttyTabs.xcodeproj/project.pbxproj`
   - Commit message: `Bump version to X.Y.Z`
   - Push: `git push -u origin release/vX.Y.Z`

7. **Create a pull request**
   - Create PR: `gh pr create --title "Release vX.Y.Z" --body "...changelog summary..."`
   - Include the changelog entries in the PR body

8. **Monitor CI**
   - Watch the CI workflow: `gh pr checks --watch`
   - If CI fails, fix the issues and push again
   - Wait for all checks to pass before proceeding

9. **Merge the PR**
   - Merge: `gh pr merge --squash --delete-branch`
   - Switch back to main: `git checkout main && git pull`

10. **Create and push the tag**
    - Create tag: `git tag vX.Y.Z`
    - Push tag: `git push origin vX.Y.Z`

11. **Monitor the release workflow**
    - Watch: `gh run watch --repo manaflow-ai/cmux`
    - Verify the release appears at: https://github.com/manaflow-ai/cmux/releases
    - Check that the DMG is attached to the release

12. **Verify homebrew cask update**
    - The "Update Homebrew Cask" workflow triggers automatically after the release workflow completes
    - Watch: `gh run list --workflow=update-homebrew.yml --limit=1` and `gh run watch`
    - Verify: `cd homebrew-cmux && git pull && grep version Casks/cmux.rb`
    - Run `bash tests/test_homebrew_sha.sh` to confirm the SHA matches

13. **Notify**
    - On success: `say "cmux release complete"`
    - On failure: `say "cmux release failed"`

## Changelog Guidelines

**Include only end-user visible changes:**
- New features users can see or interact with
- Bug fixes users would notice (crashes, UI glitches, incorrect behavior)
- Performance improvements users would feel
- UI/UX changes
- Breaking changes or removed features

**Exclude internal/developer changes:**
- Setup scripts, build scripts, reload scripts
- CI/workflow changes
- Documentation updates (README, CONTRIBUTING, CLAUDE.md)
- Test additions or fixes
- Internal refactoring with no user-visible effect
- Dependency updates (unless they fix a user-facing bug)

**Writing style:**
- Use present tense ("Add feature" not "Added feature")
- Group by category: Added, Changed, Fixed, Removed
- Be concise but descriptive
- Focus on what the user experiences, not how it was implemented
- Link to issues/PRs if relevant

## Contributor Credits

Credit the people who made each release happen. This builds community and encourages contributions.

**Per-entry attribution** — append contributor credit after each changelog bullet:
- For code contributions (PR author): `— thanks @user!`
- For bug reports (issue reporter, if different from PR author): `— thanks @reporter for the report!`
- Core team (`lawrencecchen`, `austinywang`) contributions get no per-entry callout — core work is the baseline

**Summary section** — add a "Thanks to N contributors!" section at the bottom of each release:
```markdown
### Thanks to N contributors!

- [@user1](https://github.com/user1)
- [@user2](https://github.com/user2)
```
- List all contributors alphabetically by GitHub handle (including core team)
- Link each handle to their GitHub profile
- Include everyone: PR authors, issue reporters, anyone whose work is in the release

**GitHub Release body** — when the release is published, the GitHub Release should also include the "Thanks to N contributors!" section with linked handles.

## Example Changelog Entry

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
- [@lawrencechen](https://github.com/lawrencechen)
- [@reporter](https://github.com/reporter)
```
