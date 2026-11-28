// swift-tools-version: 6.0

import PackageDescription

// The iPhone side of feed pushes (plans/cmux-next/feed.md 7.3), platform
// neutral so it tests with `swift test` on macOS: notification categories and
// their actions, the push payload, the answer each action sends, and the
// `/v1/ops` request bodies for push targets and feed answers.
let package = Package(
    name: "CmuxFeedPushCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CmuxFeedPushCore", targets: ["CmuxFeedPushCore"])],
    targets: [
        .target(name: "CmuxFeedPushCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "CmuxFeedPushCoreTests", dependencies: ["CmuxFeedPushCore"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
