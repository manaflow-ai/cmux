// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxRemoteWorkspace",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxRemoteWorkspace",
            targets: ["CmuxRemoteWorkspace"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxFoundation"),
        .package(path: "../CmuxCore"),
        .package(path: "../CmuxRemoteDaemon"),
        .package(path: "../CmuxSocketControl"),
    ],
    targets: [
        .target(
            name: "CmuxRemoteWorkspace",
            dependencies: [
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
                .product(name: "CmuxCore", package: "CmuxCore"),
                .product(name: "CmuxRemoteDaemon", package: "CmuxRemoteDaemon"),
                .product(name: "CmuxSocketControl", package: "CmuxSocketControl"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxRemoteWorkspaceTests",
            dependencies: ["CmuxRemoteWorkspace"]
        ),
    ]
)
