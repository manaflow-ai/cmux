// swift-tools-version: 6.0

import PackageDescription

// Bridges cmux Cloud machines into the phone's workspace experience: Cloud
// workspaces become ordinary workspace rows in the shell store, and Cloud
// terminals are served through the same surface the paired-Mac path uses, so
// the workspace list, the detail chrome, the terminal and the composer are
// the same views with the same behavior.
//
// The Cloud domain package knows nothing about the shell, and the shell knows
// nothing about Cloud; this package is the only place both are named.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "CmuxMobileCloudBridge",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxMobileCloudBridge", targets: ["CmuxMobileCloudBridge"]),
    ],
    dependencies: [
        .package(path: "../CmuxMobileCloud"),
        .package(path: "../CmuxMobileShell"),
        .package(path: "../CmuxMobileShellModel"),
    ],
    targets: [
        .target(
            name: "CmuxMobileCloudBridge",
            dependencies: [
                "CmuxMobileCloud",
                "CmuxMobileShell",
                "CmuxMobileShellModel",
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CmuxMobileCloudBridgeTests",
            dependencies: ["CmuxMobileCloudBridge", "CmuxMobileCloud"],
            swiftSettings: swiftSettings
        ),
    ]
)
