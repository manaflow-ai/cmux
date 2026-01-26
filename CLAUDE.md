# GhosttyTabs agent notes

## Release

Tagging a version triggers the GitHub Actions release workflow and uploads the notarized zip.

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
gh run watch --repo manaflow-ai/GhosttyTabs
```

Notes:
- Requires GitHub secrets: `APPLE_CERTIFICATE_BASE64`, `APPLE_CERTIFICATE_PASSWORD`,
  `APPLE_SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`.
- The release asset is `GhosttyTabs-macos.zip` attached to the tag.
- README download button points to `releases/latest/download/GhosttyTabs-macos.zip`.
