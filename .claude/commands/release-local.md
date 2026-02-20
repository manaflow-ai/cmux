# Release Local

Full end-to-end release built locally. Bumps version, updates changelog, tags, then builds/signs/notarizes/uploads via `scripts/build-sign-upload.sh`.

## Steps

### 1. Determine the new version number

- Get the current version from `cmux.xcodeproj/project.pbxproj` (look for `MARKETING_VERSION`)
- Bump the minor version unless the user specifies otherwise (e.g., 0.54.0 → 0.55.0)

### 2. Gather changes since the last release

- Find the most recent git tag: `git describe --tags --abbrev=0`
- Get commits since that tag: `git log --oneline <last-tag>..HEAD --no-merges`
- **Filter for end-user visible changes only** — ignore developer tooling, CI, docs, tests
- Categorize changes into: Added, Changed, Fixed, Removed
- If there are no user-facing changes, ask the user if they still want to release

### 3. Update the changelog

- Add a new section at the top of `CHANGELOG.md` with the new version and today's date
- **Only include changes that affect the end-user experience**
- Write clear, user-facing descriptions (not raw commit messages)
- Also update `docs-site/content/docs/changelog.mdx` if it exists

### 4. Bump the version

- Run: `./scripts/bump-version.sh` (bumps minor by default)

### 5. Commit, tag, and push

- Stage: `CHANGELOG.md`, `cmux.xcodeproj/project.pbxproj`
- Commit message: `Bump version to X.Y.Z`
- Create tag: `git tag vX.Y.Z`
- Push: `git push origin main && git push origin vX.Y.Z`

### 6. Build, sign, notarize, and upload

```bash
./scripts/build-sign-upload.sh vX.Y.Z
```

This script handles: GhosttyKit build, xcodebuild, Sparkle key injection, codesigning, notarization (app + DMG), appcast generation, GitHub release upload, homebrew cask update, and cleanup.

If the script fails, run `say "cmux release failed"`.

### 7. Verify homebrew cask

- Run `bash tests/test_homebrew_sha.sh` to confirm the cask SHA matches the release DMG
- Update the homebrew-cmux submodule pointer: `git add homebrew-cmux && git commit -m "Update homebrew-cmux submodule to latest" && git push origin main`

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
