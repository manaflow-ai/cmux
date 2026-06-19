// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxRemoteSession",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxRemoteSession",
            targets: ["CmuxRemoteSession"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxFoundation"),
        .package(path: "../CmuxCore"),
        .package(path: "../CmuxSettings"),
        .package(path: "../CmuxRemoteDaemon"),
        .package(path: "../CmuxRemoteWorkspace"),
        .package(path: "../CMUXDebugLog"),
    ],
    targets: [
        .target(
            name: "CmuxRemoteSession",
            dependencies: [
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
                .product(name: "CmuxCore", package: "CmuxCore"),
                .product(name: "CmuxSettings", package: "CmuxSettings"),
                .product(name: "CmuxRemoteDaemon", package: "CmuxRemoteDaemon"),
                .product(name: "CmuxRemoteWorkspace", package: "CmuxRemoteWorkspace"),
                .product(name: "CMUXDebugLog", package: "CMUXDebugLog"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxRemoteSessionTests",
            dependencies: [
                "CmuxRemoteSession",
                .product(name: "CmuxCore", package: "CmuxCore"),
                .product(name: "CmuxSettings", package: "CmuxSettings"),
                .product(name: "CmuxRemoteDaemon", package: "CmuxRemoteDaemon"),
                .product(name: "CmuxRemoteWorkspace", package: "CmuxRemoteWorkspace"),
            ]
        ),
    ]
)
