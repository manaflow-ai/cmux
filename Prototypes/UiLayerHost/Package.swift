// swift-tools-version: 6.2

import PackageDescription

// Debug-only host for iterating on cmux-next chrome against an exported,
// read-only projection. It depends on the small preview product, never the
// app composition root, so source saves rebuild only the leaf UI modules.
let package = Package(
    name: "UiLayerHost",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "cmux-ui-layer", targets: ["UiLayerHost"]),
        .executable(name: "cmux-ui-layer-watch", targets: ["UiLayerSourceWatcher"]),
        // A heavy module's scene host, built only when a push touches its module (ui-preview-worker.py
        // HEAVY_SCENES), so a leaf change never waits on it.
        .executable(name: "cmux-ui-home", targets: ["UiHomeHost"]),
        .executable(name: "cmux-ui-layout", targets: ["UiLayoutHost"]),
        .executable(name: "cmux-ui-browser", targets: ["UiBrowserHost"]),
        .executable(name: "cmux-ui-agentpane", targets: ["UiAgentPaneHost"]),
        .executable(name: "cmux-ui-screen", targets: ["UiScreenHost"]),
    ],
    dependencies: [
        .package(path: "../../Packages/macOS/CmuxNext"),
    ],
    targets: [
        .executableTarget(
            name: "UiLayerHost",
            dependencies: [
                .product(name: "CmuxNextUiLayerPreview", package: "CmuxNext"),
                // The UI shell's scenes (--shoot): the modules' own playground windows.
                .product(name: "CmuxNextUiShellModules", package: "CmuxNext"),
                "UiShellShootKit",
            ],
            path: "Sources/UiLayerHost"
        ),
        // --shoot's core (options, receipt, the draw into PNG): AppKit only, shared by every scene host.
        .target(name: "UiShellShootKit", path: "Sources/UiShellShootKit"),
        .executableTarget(
            name: "UiHomeHost",
            dependencies: [
                .product(name: "CmuxNextUiHomeModules", package: "CmuxNext"),
                "UiShellShootKit",
            ],
            path: "Sources/UiHomeHost"
        ),
        .executableTarget(
            name: "UiLayoutHost",
            dependencies: [
                .product(name: "CmuxNextUiLayoutModules", package: "CmuxNext"),
                "UiShellShootKit",
            ],
            path: "Sources/UiLayoutHost"
        ),
        .executableTarget(
            name: "UiBrowserHost",
            dependencies: [
                .product(name: "CmuxNextUiBrowserModules", package: "CmuxNext"),
                "UiShellShootKit",
            ],
            path: "Sources/UiBrowserHost"
        ),
        .executableTarget(
            name: "UiAgentPaneHost",
            dependencies: [
                .product(name: "CmuxNextUiAgentPaneModules", package: "CmuxNext"),
                "UiShellShootKit",
            ],
            path: "Sources/UiAgentPaneHost"
        ),
        .executableTarget(
            name: "UiScreenHost",
            dependencies: [
                .product(name: "CmuxNextUiScreenModules", package: "CmuxNext"),
                "UiShellShootKit",
            ],
            path: "Sources/UiScreenHost"
        ),
        .executableTarget(name: "UiLayerSourceWatcher", path: "Sources/UiLayerSourceWatcher"),
        .testTarget(name: "UiLayerHostTests", dependencies: ["UiLayerHost", "UiShellShootKit"]),
    ]
)
