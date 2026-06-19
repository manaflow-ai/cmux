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
        // CmuxCore owns the WorkspaceRemote* value types carried by
        // SelectedWorkspaceDirectorySnapshot.
        .package(path: "../CmuxCore"),
        // WorkspaceGroupNewPlacement (the typed setting value for new
        // in-group workspace placement) is owned by CmuxSettings.
        .package(path: "../CmuxSettings"),
        // Bonsplit drives the Window/ tmux pane-overlay geometry.
        .package(path: "../../../vendor/bonsplit"),
        // CMUXDebugLog backs the Session/ snapshot-restore logging.
        .package(path: "../CMUXDebugLog"),
        // CmuxTestSupport backs FileOpen/ PreferredEditorService UI-test capture.
        .package(path: "../CmuxTestSupport"),
        // SessionDisplayGeometry (the live-screen geometry value the session
        // frame resolver reads) is owned by CmuxWindowing.
        .package(path: "../CmuxWindowing"),
    ],
    targets: [
        .target(
            name: "CmuxWorkspaces",
            dependencies: [
                .product(name: "CmuxCore", package: "CmuxCore"),
                .product(name: "CmuxSettings", package: "CmuxSettings"),
                .product(name: "Bonsplit", package: "bonsplit"),
                .product(name: "CMUXDebugLog", package: "CMUXDebugLog"),
                .product(name: "CmuxTestSupport", package: "CmuxTestSupport"),
                .product(name: "CmuxWindowing", package: "CmuxWindowing"),
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
                .product(name: "CmuxCore", package: "CmuxCore"),
                .product(name: "Bonsplit", package: "bonsplit"),
                .product(name: "CmuxTestSupport", package: "CmuxTestSupport"),
                .product(name: "CmuxWindowing", package: "CmuxWindowing"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
