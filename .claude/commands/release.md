# Release

Prepare a new release for cmuxterm. This command updates the changelog, bumps the version, and creates a release tag.

## Steps

1. **Determine the new version number**
   - Get the current version from `GhosttyTabs.xcodeproj/project.pbxproj` (look for `MARKETING_VERSION`)
   - Bump the minor version unless the user specifies otherwise (e.g., 1.12.0 → 1.13.0)

2. **Gather changes since the last release**
   - Find the most recent git tag: `git describe --tags --abbrev=0`
   - Get commits since that tag: `git log --oneline <last-tag>..HEAD --no-merges`
   - Categorize changes into: Added, Changed, Fixed, Removed

3. **Update the changelog**
   - Add a new section at the top of `CHANGELOG.md` with the new version and today's date
   - Write clear, user-facing descriptions (not raw commit messages)
   - Focus on what matters to users: new features, bug fixes, breaking changes
   - Also update `docs-site/content/docs/changelog.mdx` with the same content

4. **Bump the version in Xcode project**
   - Update all occurrences of `MARKETING_VERSION` in `GhosttyTabs.xcodeproj/project.pbxproj`
   - There are typically 4 occurrences (Debug/Release for main app and CLI)

5. **Commit the changes**
   - Stage: `CHANGELOG.md`, `docs-site/content/docs/changelog.mdx`, `GhosttyTabs.xcodeproj/project.pbxproj`
   - Commit message: `Bump version to X.Y.Z`

6. **Create and push the tag**
   - Create tag: `git tag vX.Y.Z`
   - Push commits: `git push origin main`
   - Push tag: `git push origin vX.Y.Z`

7. **Monitor the release**
   - Watch the workflow: `gh run watch --repo manaflow-ai/cmuxterm`
   - Verify the release appears at: https://github.com/manaflow-ai/cmuxterm/releases

## Changelog Guidelines

- Use present tense ("Add feature" not "Added feature")
- Group by category: Added, Changed, Fixed, Removed
- Be concise but descriptive
- Focus on user impact, not implementation details
- Link to issues/PRs if relevant

## Example Changelog Entry

```markdown
## [1.13.0] - 2025-01-30

### Added
- New keyboard shortcut for quick tab switching

### Fixed
- Memory leak when closing split panes
- Notification badges not clearing properly

### Changed
- Improved terminal rendering performance
```
