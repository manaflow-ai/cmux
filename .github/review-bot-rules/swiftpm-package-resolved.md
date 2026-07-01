# SwiftPM Package.resolved Policy

Apply this rule to SwiftPM package, Xcode project, `.gitignore`, workflow, and dependency changes.

## Fail

- A cmux-owned package `.gitignore` ignores `Package.resolved`.
- A cmux-owned `Package.swift` dependency change resolves new or changed external pins without the matching package-local `Package.resolved` diff.
- A `cmux.xcodeproj` SwiftPM package-reference change omits the root Xcode `Package.resolved` diff.
- A review treats `cmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` as sufficient proof for standalone package resolution.

## Pass

- cmux-owned package-local `Package.resolved` files are committed with SwiftPM dependency changes.
- The root Xcode project lockfile is committed for Xcode project/workspace dependency changes.
- Vendored third-party directories preserve their upstream `Package.resolved` ignore policy.

## Report

Name the package root or Xcode project file and explain that standalone SwiftPM commands resolve against a package's own `Package.resolved`, while Xcode project package references resolve against the root Xcode lockfile; dependency pin changes must be visible in PR diffs.
