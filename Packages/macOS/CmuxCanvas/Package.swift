// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxCanvas",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "CmuxCanvas",
            targets: ["CmuxCanvas"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxCanvas",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxCanvasTests",
            dependencies: [
                "CmuxCanvas",
            ]
        ),
    ]
)
