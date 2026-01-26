# cmux

Vertical tabs for Ghostty on macOS, built on libghostty.

[![Download macOS](https://img.shields.io/badge/Download-macOS-1b5fdd?style=for-the-badge&logo=apple)](releases/latest/download/cmux-macos.zip)

## Releases

Tag a version like `v0.1.0` and push it to trigger the GitHub Actions release workflow.
The workflow builds `GhosttyKit.xcframework`, builds the Release app, signs, notarizes,
staples, and uploads `cmux-macos.zip` to the release.

### Required GitHub secrets

- `APPLE_CERTIFICATE_BASE64`: Base64-encoded Developer ID Application .p12
- `APPLE_CERTIFICATE_PASSWORD`: Password for the .p12
- `APPLE_SIGNING_IDENTITY`: e.g. `Developer ID Application: Your Name (TEAMID)`
- `APPLE_ID`: Apple ID used for notarization
- `APPLE_APP_SPECIFIC_PASSWORD`: App-specific password for the Apple ID
- `APPLE_TEAM_ID`: Apple Developer Team ID
