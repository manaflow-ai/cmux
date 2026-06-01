// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxGitHub",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxGitHub",
            targets: ["CmuxGitHub"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxGitHub",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxGitHubTests",
            dependencies: ["CmuxGitHub"]
        ),
    ]
)
