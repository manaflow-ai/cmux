// swift-tools-version: 6.0

import PackageDescription

// Platform-neutral Home client core: the conversation model (same shapes as the
// conversation owner's wire contract), the HomeSource protocol every backend
// implements (mock, local daemon, cloud), the confirmed mirror + intent log,
// contact parsing for invites, and search over Home messages. No UIKit/AppKit,
// so it builds and tests on macOS with `swift test` and serves iOS and macOS.
let package = Package(
    name: "CmuxHomeCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxHomeCore", targets: ["CmuxHomeCore"]),
    ],
    dependencies: [
        // Agent questions (plans/cmux-next/agent-questions.md): the `question` part's model.
        .package(path: "../CmuxAgentQuestion"),
    ],
    targets: [
        .target(
            name: "CmuxHomeCore",
            dependencies: [.product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxHomeCoreTests",
            dependencies: ["CmuxHomeCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
