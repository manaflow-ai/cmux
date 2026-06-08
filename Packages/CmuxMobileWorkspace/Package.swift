// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMobileWorkspace",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileWorkspace",
            targets: ["CmuxMobileWorkspace"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxMobileShellModel"),
    ],
    targets: [
        .target(
            name: "CmuxMobileWorkspace",
            dependencies: [
                "CmuxMobileShellModel",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxMobileWorkspaceTests",
            dependencies: ["CmuxMobileWorkspace"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
