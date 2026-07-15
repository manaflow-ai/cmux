// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxFoundation",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxFoundation",
            targets: ["CmuxFoundation"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxFoundationAtomicsC",
            publicHeadersPath: "include"
        ),
        .target(
            name: "CmuxFoundation",
            dependencies: ["CmuxFoundationAtomicsC"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxFoundationTests",
            dependencies: ["CmuxFoundation"]
        ),
    ]
)
