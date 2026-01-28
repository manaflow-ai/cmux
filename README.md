# cmuxterm

Vertical tabs for Ghostty on macOS, built on libghostty.

[![Download macOS](https://img.shields.io/badge/Download-macOS-1b5fdd?style=for-the-badge&logo=apple)](releases/latest/download/cmuxterm-macos.dmg)

## Releases

Tag a version like `v0.1.0` and push it to trigger the GitHub Actions release workflow.
The workflow builds `GhosttyKit.xcframework`, builds the Release app, signs, notarizes,
staples, and uploads `cmuxterm-macos.dmg` to the release.

## Auto updates

cmuxterm uses Sparkle with the same update UI flow as upstream Ghostty. The app looks for
an appcast at:

```
https://github.com/manaflow-ai/cmuxterm/releases/latest/download/appcast.xml
```

To sign updates, set these secrets for release builds:

- `SPARKLE_PUBLIC_KEY`: Sparkle EdDSA public key (embedded in the app).
- `SPARKLE_PRIVATE_KEY`: Sparkle EdDSA private key (used when generating appcasts).

You still need to generate and upload `appcast.xml` alongside each release asset.

To generate keys locally (stores the private key in your Keychain and appends values
to `.env`), run:

```bash
./scripts/sparkle_generate_keys.sh
```

For manual appcast generation (uses `SPARKLE_PRIVATE_KEY`):

```bash
SPARKLE_PRIVATE_KEY=... ./scripts/sparkle_generate_appcast.sh cmuxterm-macos.dmg vX.Y.Z appcast.xml
```

### Required GitHub secrets

- `APPLE_CERTIFICATE_BASE64`: Base64-encoded Developer ID Application .p12
- `APPLE_CERTIFICATE_PASSWORD`: Password for the .p12
- `APPLE_SIGNING_IDENTITY`: e.g. `Developer ID Application: Your Name (TEAMID)`
- `APPLE_ID`: Apple ID used for notarization
- `APPLE_APP_SPECIFIC_PASSWORD`: App-specific password for the Apple ID
- `APPLE_TEAM_ID`: Apple Developer Team ID
- `SPARKLE_PUBLIC_KEY`: Sparkle EdDSA public key for update verification
- `SPARKLE_PRIVATE_KEY`: Sparkle EdDSA private key for appcast signing
