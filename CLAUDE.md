# cmuxterm agent notes

## Local dev

After making code changes, always run the build:

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' build
```

`reload` = kill and launch the Debug app only:

```bash
./scripts/reload.sh
```

`reloadp` = kill and launch the Release app:

```bash
./scripts/reloadp.sh
```

`reload2` = reload both Debug and Release:

```bash
./scripts/reload2.sh
```

## E2E mac UI tests

Run UI tests on the UTM macOS VM (never on the host machine):

```bash
ssh cmux-vm 'cd /Users/cmux/GhosttyTabs && xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination "platform=macOS" -only-testing:GhosttyTabsUITests/UpdatePillUITests test'
```

## Release

Tagging a version triggers the GitHub Actions release workflow and uploads the notarized zip.

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
gh run watch --repo manaflow-ai/cmuxterm
```

Notes:
- Requires GitHub secrets: `APPLE_CERTIFICATE_BASE64`, `APPLE_CERTIFICATE_PASSWORD`,
  `APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`.
- The release asset is `cmuxterm-macos.dmg` attached to the tag.
- README download button points to `releases/latest/download/cmuxterm-macos.dmg`.
- Versioning: bump the minor version for updates unless explicitly asked otherwise.
