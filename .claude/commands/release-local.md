# Release Local

Release straight from `main` with no PR, built and published locally.

Follow [release.md](release.md) "Shared prep" (version, changelog, contributors, `./scripts/bump-version.sh`) and its changelog and contributor-credit rules. `skills/cmux-release/SKILL.md` covers the bump and tag mechanics.

## Delta: no PR, tag on main, local build

1. **Commit on main.** Stage `CHANGELOG.md` and `cmux.xcodeproj/project.pbxproj`, commit `Bump version to X.Y.Z`.

2. **Guard, tag, push.**

   ```bash
   ./scripts/release-pretag-guard.sh
   git tag vX.Y.Z
   git push origin main && git push origin vX.Y.Z
   ```

   If the guard fails, run `./scripts/bump-version.sh`, commit the build-number bump, and rerun the guard.

3. **Build, sign, notarize, upload.**

   ```bash
   ./scripts/build-sign-upload.sh vX.Y.Z
   ```

   The script does GhosttyKit build, xcodebuild, Sparkle key injection, codesigning, notarization of app and DMG, appcast generation, GitHub release upload of `cmux-macos.dmg` and `appcast.xml`, homebrew cask update, cleanup, and `say "cmux release complete"` on success. Pass `--allow-overwrite` only to replace existing assets on the same tag during an emergency reroll. If it fails, run `say "cmux release failed"`.

4. **Verify and land the homebrew cask.**

   ```bash
   bash tests/test_homebrew_sha.sh
   git add homebrew-cmux && git commit -m "Update homebrew-cmux submodule to latest" && git push origin main
   ```
