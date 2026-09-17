// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxWorkspaceShare",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxWorkspaceShare", targets: ["CmuxWorkspaceShare"]),
    ],
    targets: [
        .target(
            name: "CmuxWorkspaceShare",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxWorkspaceShareTests",
            dependencies: ["CmuxWorkspaceShare"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
