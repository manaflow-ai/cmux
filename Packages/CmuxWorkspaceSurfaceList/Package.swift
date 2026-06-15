// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxWorkspaceSurfaceList",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxWorkspaceSurfaceList",
            targets: ["CmuxWorkspaceSurfaceList"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxWorkspaceSurfaceList",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxWorkspaceSurfaceListTests",
            dependencies: ["CmuxWorkspaceSurfaceList"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
