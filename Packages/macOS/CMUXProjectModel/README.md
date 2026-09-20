# CMUXProjectModel

This package depends on XcodeProj, which in turn depends on PathKit. PathKit 1.0.1
uses a Swift 4.2 manifest and cannot participate in Xcode explicit-module
compilation caching, so cmux temporarily mirrors that dependency to the public
`manaflow-ai/PathKit` 1.0.2 fork. The fork is based on `kylef/PathKit` tag
1.0.1, changes only the Swift tools-version line, and does not imply upstream
endorsement.

The mirror lives in `config/swiftpm/mirrors.json`. SwiftPM does not inherit mirror
configuration from a parent repository, so this package links to that file from
`.swiftpm/configuration/mirrors.json`, and the Xcode workspace links to it the same
way. Standalone commands need no setup:

```bash
swift test --package-path Packages/macOS/CMUXProjectModel
```

The cmux build and test scripts and CI also export `SWIFTPM_MIRROR_CONFIG` with the same file. The
mirror and the PathKit 1.0.2 lockfile pins can be removed when upstream PathKit
publishes a modern tools-version manifest.
