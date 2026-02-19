# Release Nightly

End-to-end release: bump version, update changelog, create PR, merge, tag, build locally, sign, notarize, upload DMG. Combines `/release` + `/release-local` into a single command.

## Secrets

Source secrets directly (do NOT rely on direnv):

```bash
source ~/.secrets/cmuxterm.env && export SPARKLE_PRIVATE_KEY
```

## Signing Identity

The Manaflow signing identity exists in both login and system keychains. Always use the SHA-1 hash to avoid ambiguity:

```
SIGN_HASH="A050CC7E193C8221BDBA204E731B046CDCCC1B30"
```

Use `$SIGN_HASH` instead of `$APPLE_SIGNING_IDENTITY` for all codesign and create-dmg commands.

## Steps

### Phase 1: Version bump, changelog, PR, merge, tag (same as /release)

1. **Determine the new version number**
   - Get the current version from `GhosttyTabs.xcodeproj/project.pbxproj` (look for `MARKETING_VERSION`)
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
   - Stage: `CHANGELOG.md`, `GhosttyTabs.xcodeproj/project.pbxproj`
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

### Phase 2: Local build, sign, notarize, upload (same as /release-local)

10. **Build GhosttyKit (if needed)**

Skip if `GhosttyKit.xcframework` already exists.

```bash
if [ ! -d "GhosttyKit.xcframework" ]; then
  cd ghostty && zig build -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=native -Doptimize=ReleaseFast && cd ..
  rm -rf GhosttyKit.xcframework
  cp -R ghostty/macos/GhosttyKit.xcframework GhosttyKit.xcframework
fi
```

11. **Build app (Release, unsigned)**

```bash
rm -rf build/
xcodebuild -scheme cmux -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

12. **Inject Sparkle keys into Info.plist**

```bash
source ~/.secrets/cmuxterm.env && export SPARKLE_PRIVATE_KEY
SPARKLE_PUBLIC_KEY_DERIVED=$(swift scripts/derive_sparkle_public_key.swift "$SPARKLE_PRIVATE_KEY")
APP_PLIST="build/Build/Products/Release/cmux.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$APP_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$APP_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY_DERIVED" "$APP_PLIST"
/usr/libexec/PlistBuddy -c "Add :SUFeedURL string https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml" "$APP_PLIST"
```

13. **Codesign app**

```bash
APP_PATH="build/Build/Products/Release/cmux.app"
ENTITLEMENTS="cmux.entitlements"
SIGN_HASH="A050CC7E193C8221BDBA204E731B046CDCCC1B30"
CLI_PATH="$APP_PATH/Contents/Resources/bin/cmux"
if [ -f "$CLI_PATH" ]; then
  /usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_HASH" --entitlements "$ENTITLEMENTS" "$CLI_PATH"
fi
/usr/bin/codesign --force --options runtime --timestamp --sign "$SIGN_HASH" --entitlements "$ENTITLEMENTS" --deep "$APP_PATH"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
```

14. **Notarize app**

```bash
source ~/.secrets/cmuxterm.env
APP_PATH="build/Build/Products/Release/cmux.app"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" cmux-notary.zip
xcrun notarytool submit cmux-notary.zip --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
rm -f cmux-notary.zip
```

15. **Create and notarize DMG**

```bash
source ~/.secrets/cmuxterm.env
APP_PATH="build/Build/Products/Release/cmux.app"
SIGN_HASH="A050CC7E193C8221BDBA204E731B046CDCCC1B30"
rm -f cmux-macos.dmg
create-dmg --codesign "$SIGN_HASH" cmux-macos.dmg "$APP_PATH"
xcrun notarytool submit cmux-macos.dmg --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --wait
xcrun stapler staple cmux-macos.dmg
xcrun stapler validate cmux-macos.dmg
```

16. **Generate Sparkle appcast**

```bash
source ~/.secrets/cmuxterm.env && export SPARKLE_PRIVATE_KEY
./scripts/sparkle_generate_appcast.sh cmux-macos.dmg "$TAG" appcast.xml
```

17. **Upload to GitHub release**

If no release exists for the tag yet, create one:

```bash
gh release create "$TAG" cmux-macos.dmg appcast.xml --title "$TAG" --notes "...changelog..."
```

If it already exists:

```bash
gh release upload "$TAG" cmux-macos.dmg appcast.xml --clobber
```

18. **Cleanup and notify**

```bash
rm -rf build/ cmux-macos.dmg appcast.xml
say "Release complete"
```

## Completion

When the release is fully done (DMG uploaded, release verified), always run:

```bash
say "cmux release $TAG is live"
```

If the release fails at any point, run:

```bash
say "cmux release failed"
```

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
