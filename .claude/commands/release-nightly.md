# Release Nightly

End-to-end release via PR flow: bump version, update changelog, create PR, merge, tag, then build locally via `scripts/build-sign-upload.sh`.

## Steps

### Phase 1: Version bump, changelog, PR, merge, tag

1. **Determine the new version number**
   - Get the current version from `cmux.xcodeproj/project.pbxproj` (look for `MARKETING_VERSION`)
   - Bump the minor version unless the user specifies otherwise (e.g., 0.48.0 → 0.49.0)

2. **Create a release branch**
   - Create branch: `git checkout -b release/vX.Y.Z`

3. **Gather changes since the last release**
   - Find the most recent git tag: `git describe --tags --abbrev=0`
   - Get commits since that tag: `git log --oneline <last-tag>..HEAD --no-merges`
   - **Filter for end-user visible changes only** - ignore developer tooling, CI, docs, tests
   - Categorize changes into: Added, Changed, Fixed, Removed

4. **Update the changelog**
   - Add a new section at the top of `CHANGELOG.md` with the new version and today's date
   - **Only include changes that affect the end-user experience**
   - Write clear, user-facing descriptions (not raw commit messages)
   - Also update `docs-site/content/docs/changelog.mdx` if it exists
   - If there are no user-facing changes, ask the user if they still want to release

5. **Bump the version**
   - Run `./scripts/bump-version.sh` (bumps minor by default)

6. **Commit and push the release branch**
   - Stage: `CHANGELOG.md`, `cmux.xcodeproj/project.pbxproj`
   - Commit message: `Bump version to X.Y.Z`
   - Push: `git push -u origin release/vX.Y.Z`

7. **Create PR and wait for CI**
   - `gh pr create --title "Release vX.Y.Z" --body "...changelog..."`
   - `gh pr checks --watch`

8. **Merge PR**
   - `gh pr merge --squash --delete-branch`
   - `git checkout main && git pull`

9. **Create and push the tag**
   - `git tag vX.Y.Z && git push origin vX.Y.Z`

### Phase 2: Local build, sign, notarize, upload

10. **Run the build script**

```bash
./scripts/build-sign-upload.sh vX.Y.Z
```

This script handles: GhosttyKit build, xcodebuild, Sparkle key injection, codesigning, notarization (app + DMG), appcast generation, GitHub release upload, and cleanup.

If the script fails, run `say "cmux release failed"`.

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
