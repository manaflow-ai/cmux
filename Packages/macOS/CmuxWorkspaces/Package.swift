// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxWorkspaces",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxWorkspaces",
            targets: ["CmuxWorkspaces"]
        ),
    ],
    dependencies: [
        // WorkspaceGroupNewPlacement (the typed setting value for new
        // in-group workspace placement) is owned by CmuxSettings.
        .package(path: "../CmuxSettings"),
        // Bonsplit drives the Window/ tmux pane-overlay geometry.
        .package(path: "../../../vendor/bonsplit"),
        // CMUXDebugLog backs the Session/ snapshot-restore logging.
        .package(path: "../CMUXDebugLog"),
        // CmuxTestSupport backs FileOpen/ PreferredEditorService UI-test capture.
        .package(path: "../CmuxTestSupport"),
        // CMUXAgentLaunch is a leaf service dependency used only by the
        // incident-shaped restore acceptance suite.
        .package(path: "../CMUXAgentLaunch"),
    ],
    targets: [
        .target(
            name: "CmuxWorkspaces",
            dependencies: [
                .product(name: "CmuxSettings", package: "CmuxSettings"),
                .product(name: "Bonsplit", package: "bonsplit"),
                .product(name: "CMUXDebugLog", package: "CMUXDebugLog"),
                .product(name: "CmuxTestSupport", package: "CmuxTestSupport"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxWorkspacesTests",
            dependencies: [
                "CmuxWorkspaces",
                .product(name: "CMUXAgentLaunch", package: "CMUXAgentLaunch"),
                .product(name: "Bonsplit", package: "bonsplit"),
                .product(name: "CmuxTestSupport", package: "CmuxTestSupport"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
