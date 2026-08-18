// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxFilePreviewSyntax",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxFilePreviewSyntax",
            targets: ["CmuxFilePreviewSyntax"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxFilePreviewSyntax",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxFilePreviewSyntaxTests",
            dependencies: ["CmuxFilePreviewSyntax"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
