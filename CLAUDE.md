# cmuxterm agent notes

## Initial setup

Run the setup script to initialize submodules and build GhosttyKit:

```bash
./scripts/setup.sh
```

## Local dev

After making code changes, always run the reload script to launch the Debug app:

```bash
./scripts/reload.sh
```

After making code changes, always run the build:

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination 'platform=macOS' build
```

When rebuilding GhosttyKit.xcframework, always use Release optimizations:

```bash
cd ghostty && zig build -Demit-xcframework=true -Doptimize=ReleaseFast
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

Run UI tests on the UTM macOS VM (never on the host machine). Always run e2e UI tests via `ssh cmux-vm`:

```bash
ssh cmux-vm 'cd /Users/cmux/GhosttyTabs && xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination "platform=macOS" -only-testing:GhosttyTabsUITests/UpdatePillUITests test'
```

## Basic tests

Run basic automated tests on the UTM macOS VM (never on the host machine):

```bash
ssh cmux-vm 'cd /Users/cmux/GhosttyTabs && xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux -configuration Debug -destination "platform=macOS" build && pkill -x "cmuxterm DEV" || true && APP=$(find /Users/cmux/Library/Developer/Xcode/DerivedData -path "*/Build/Products/Debug/cmuxterm DEV.app" -print -quit) && open "$APP" && for i in {1..20}; do [ -S /tmp/cmuxterm.sock ] && break; sleep 0.5; done && python3 tests/test_update_timing.py && python3 tests/test_signals_auto.py && python3 tests/test_ctrl_socket.py && python3 tests/test_notifications.py'
```

## Ghostty submodule workflow

Ghostty changes must be committed in the `ghostty` submodule and pushed to the `manaflow-ai/ghostty` fork.
Keep `docs/ghostty-fork.md` up to date with any fork changes and conflict notes.

```bash
cd ghostty
git remote -v  # origin = upstream, manaflow = fork
git checkout -b <branch>
git add <files>
git commit -m "..."
git push manaflow <branch>
```

To keep the fork up to date with upstream:

```bash
cd ghostty
git fetch origin
git checkout main
git merge origin/main
git push manaflow main
```

Then update the parent repo with the new submodule SHA:

```bash
cd ..
git add ghostty
git commit -m "Update ghostty submodule"
```

## Release

Use the `/release` command to prepare a new release. This will:
1. Determine the new version (bumps minor by default)
2. Gather commits since the last tag and update the changelog
3. Update `CHANGELOG.md` and `docs-site/content/docs/changelog.mdx`
4. Bump `MARKETING_VERSION` in the Xcode project
5. Commit, tag, and push

Manual release steps (if not using the command):

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
- Changelog: always update both `CHANGELOG.md` and the docs-site version.
