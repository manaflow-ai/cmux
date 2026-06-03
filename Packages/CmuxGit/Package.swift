// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxGit",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxGit",
            targets: ["CmuxGit"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxGit",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxGitTests",
            dependencies: ["CmuxGit"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
