// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxArtifactCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxArtifactCore",
            targets: ["CmuxArtifactCore"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxArtifactCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxArtifactCoreTests",
            dependencies: ["CmuxArtifactCore"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
