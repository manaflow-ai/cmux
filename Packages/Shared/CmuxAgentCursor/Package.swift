// swift-tools-version: 6.0
// The agent cursor shared by the cmux app (browser and app surfaces) and the
// cmux Computer Use helper (desktop windows). CoreAnimation only: one path
// plan per action becomes one keyframe animation; no timers while idle.
import PackageDescription

let package = Package(
    name: "CmuxAgentCursor",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CmuxAgentCursor", targets: ["CmuxAgentCursor"]),
    ],
    targets: [
        .target(name: "CmuxAgentCursor"),
        .testTarget(
            name: "CmuxAgentCursorTests",
            dependencies: ["CmuxAgentCursor"],
            resources: [.copy("Resources")]
        ),
    ]
)
