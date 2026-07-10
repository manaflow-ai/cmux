// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxIrohTransport",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxIrohTransport",
            targets: ["CmuxIrohTransport"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxIrohTransport",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxIrohTransportTests",
            dependencies: ["CmuxIrohTransport"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
