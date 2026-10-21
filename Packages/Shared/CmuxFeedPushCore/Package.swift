// swift-tools-version: 6.0

import PackageDescription

// Linux has no CryptoKit; swift-crypto provides the same API there.
var packageDependencies: [Package.Dependency] = []
var cryptoDependencies: [Target.Dependency] = []
#if os(Linux)
packageDependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"))
cryptoDependencies.append(.product(name: "Crypto", package: "swift-crypto"))
#endif

// The iPhone side of feed pushes (plans/cmux-next/feed.md 7.3), platform
// neutral so it tests with `swift test` on macOS: notification categories and
// their actions, the push payload, the answer each action sends, and the
// `/v1/ops` request bodies for push targets and feed answers.
let package = Package(
    name: "CmuxFeedPushCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CmuxFeedPushCore", targets: ["CmuxFeedPushCore"])],
    dependencies: packageDependencies,
    targets: [
        .target(name: "CmuxFeedPushCore", dependencies: cryptoDependencies, swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "CmuxFeedPushCoreTests", dependencies: ["CmuxFeedPushCore"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
