// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxArtifacts",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxArtifacts", targets: ["CmuxArtifacts"]),
    ],
    dependencies: [
        .package(path: "../CmuxFoundation"),
    ],
    targets: [
        .target(
            name: "CmuxArtifacts",
            dependencies: ["CmuxFoundation"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxArtifactsTests",
            dependencies: ["CmuxArtifacts"]
        ),
    ]
)
