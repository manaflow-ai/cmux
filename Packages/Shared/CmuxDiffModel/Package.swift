// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxDiffModel",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxDiffModel",
            targets: ["CmuxDiffModel"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxDiffModel",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxDiffModelTests",
            dependencies: ["CmuxDiffModel"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
