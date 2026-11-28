# Release Nightly

Release through the PR flow, then build and publish locally instead of waiting on the CI release workflow.

Follow [release.md](release.md) "Shared prep" (version, changelog, contributors, `./scripts/bump-version.sh`) and its changelog and contributor-credit rules, then steps 5 through 8 (branch, PR, `gh pr checks --watch`, `gh pr merge --squash --delete-branch`, `./scripts/release-pretag-guard.sh`, tag and push). `skills/cmux-release/SKILL.md` covers the bump and tag mechanics.

## Delta: build locally instead of from CI

Replace steps 9 through 11 of `/release` with:

```bash
./scripts/build-sign-upload.sh vX.Y.Z
```

The script does GhosttyKit build, xcodebuild, Sparkle key injection, codesigning, notarization of app and DMG, appcast generation, GitHub release upload of `cmux-macos.dmg` and `appcast.xml`, homebrew cask update, cleanup, and `say "cmux release complete"` on success. Pass `--allow-overwrite` only to replace existing assets on the same tag during an emergency reroll.

If the script fails, run `say "cmux release failed"`.
