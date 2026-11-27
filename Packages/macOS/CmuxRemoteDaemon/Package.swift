// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxRemoteDaemon",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxRemoteDaemon",
            targets: ["CmuxRemoteDaemon"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxFoundation"),
        .package(path: "../CmuxCore"),
    ],
    targets: [
        .target(
            name: "CmuxRemoteDaemon",
            dependencies: [
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
                .product(name: "CmuxCore", package: "CmuxCore"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxRemoteDaemonTests",
            dependencies: [
                "CmuxRemoteDaemon",
                .product(name: "CmuxCore", package: "CmuxCore"),
            ]
        ),
    ]
)
