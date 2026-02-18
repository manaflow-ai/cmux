# Release Local

Build, sign, notarize, and upload a release locally (no GitHub Actions). Requires direnv to be loaded with Apple signing secrets from `~/.secrets/cmux.env`.

## Pre-flight Checks

Before starting, verify all required tools and secrets are available. Run these checks and **stop immediately** if any fail:

```bash
# Required env vars (loaded via direnv from ~/.secrets/cmux.env)
for var in APPLE_SIGNING_IDENTITY APPLE_ID APPLE_APP_SPECIFIC_PASSWORD APPLE_TEAM_ID SPARKLE_PRIVATE_KEY; do
  if [ -z "${!var:-}" ]; then echo "MISSING: $var — run 'direnv allow' or check ~/.secrets/cmux.env"; exit 1; fi
done

# Required tools
for tool in zig xcodebuild create-dmg xcrun codesign ditto gh; do
  command -v "$tool" >/dev/null || { echo "MISSING: $tool"; exit 1; }
done

# Signing identity exists in keychain
security find-identity -v -p codesigning | grep -q "$APPLE_SIGNING_IDENTITY" || { echo "Signing identity not in keychain"; exit 1; }

echo "All pre-flight checks passed"
```

## Steps

### 1. Determine version and tag

- Read current version: `grep 'MARKETING_VERSION' GhosttyTabs.xcodeproj/project.pbxproj | head -1`
- The git tag `vX.Y.Z` should already exist (created by `/release`)
- If no tag exists for the current version, ask the user what to do
- Set `TAG=vX.Y.Z` for the rest of the steps

### 2. Build GhosttyKit (if needed)

Skip if `GhosttyKit.xcframework` already exists and looks valid.

```bash
if [ ! -d "GhosttyKit.xcframework" ]; then
  cd ghostty && zig build -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=native -Doptimize=ReleaseFast && cd ..
  rm -rf GhosttyKit.xcframework
  cp -R ghostty/macos/GhosttyKit.xcframework GhosttyKit.xcframework
fi
```

### 3. Build app (Release, unsigned)

```bash
rm -rf build/
xcodebuild -scheme cmux -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

### 4. Inject Sparkle keys into Info.plist

```bash
SPARKLE_PUBLIC_KEY_DERIVED=$(swift scripts/derive_sparkle_public_key.swift "$SPARKLE_PRIVATE_KEY")
APP_PLIST="build/Build/Products/Release/cmux.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$APP_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$APP_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY_DERIVED" "$APP_PLIST"
/usr/libexec/PlistBuddy -c "Add :SUFeedURL string https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml" "$APP_PLIST"
```

### 5. Codesign app

Sign the embedded CLI binary first, then deep-sign the entire app bundle:

```bash
APP_PATH="build/Build/Products/Release/cmux.app"
ENTITLEMENTS="cmux.entitlements"
CLI_PATH="$APP_PATH/Contents/Resources/bin/cmux"
if [ -f "$CLI_PATH" ]; then
  /usr/bin/codesign --force --options runtime --timestamp --sign "$APPLE_SIGNING_IDENTITY" --entitlements "$ENTITLEMENTS" "$CLI_PATH"
fi
/usr/bin/codesign --force --options runtime --timestamp --sign "$APPLE_SIGNING_IDENTITY" --entitlements "$ENTITLEMENTS" --deep "$APP_PATH"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
```

### 6. Notarize app

```bash
APP_PATH="build/Build/Products/Release/cmux.app"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" cmux-notary.zip
xcrun notarytool submit cmux-notary.zip --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --wait
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl -a -vv --type execute "$APP_PATH"
rm -f cmux-notary.zip
```

If notarization fails, fetch the log with:
```bash
xcrun notarytool log <submission-id> --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD"
```

### 7. Create and notarize DMG

```bash
APP_PATH="build/Build/Products/Release/cmux.app"
create-dmg --identity="$APPLE_SIGNING_IDENTITY" "$APP_PATH" ./
mv ./cmux*.dmg cmux-macos.dmg
xcrun notarytool submit cmux-macos.dmg --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --wait
xcrun stapler staple cmux-macos.dmg
xcrun stapler validate cmux-macos.dmg
```

### 8. Generate Sparkle appcast

```bash
./scripts/sparkle_generate_appcast.sh cmux-macos.dmg "$TAG" appcast.xml
```

### 9. Upload to GitHub release

```bash
gh release upload "$TAG" cmux-macos.dmg appcast.xml --clobber
```

Verify the release: `gh release view "$TAG"`

### 10. Cleanup

```bash
rm -rf build/
```

## Important Notes

- Each step should be run individually so you can check output and handle errors
- Notarization typically takes 1-5 minutes per submission (app + DMG = two submissions)
- The `--wait` flag on `notarytool submit` blocks until Apple finishes processing
- If notarization fails, always fetch the log to see why before retrying
- The signing identity `Developer ID Application: Manaflow, Inc. (7WLXT3NR37)` must be in the local keychain
- This command does NOT bump versions or update changelogs — use `/release` for that first, then `/release-local` to build and upload
