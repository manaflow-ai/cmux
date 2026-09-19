# CMUXProjectModel

This package depends on XcodeProj, which in turn depends on PathKit. PathKit 1.0.1
uses a Swift 4.2 manifest and cannot participate in Xcode explicit-module
compilation caching, so cmux temporarily mirrors that dependency to the public
`manaflow-ai/PathKit` 1.0.2 fork.

SwiftPM does not inherit mirror configuration from a parent repository when a
package is resolved directly. Use the tracked mirror explicitly for standalone
commands:

```bash
SWIFTPM_MIRROR_CONFIG="$(git rev-parse --show-toplevel)/config/swiftpm/mirrors.json" \
  swift test --package-path Packages/macOS/CMUXProjectModel
```

The cmux build and test scripts and CI export this variable automatically. The
mirror and the PathKit 1.0.2 lockfile pins can be removed when upstream PathKit
publishes a modern tools-version manifest.
