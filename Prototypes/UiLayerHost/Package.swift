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
    ],
    dependencies: [
        .package(path: "../../Packages/macOS/CmuxNext"),
    ],
    targets: [
        .executableTarget(
            name: "UiLayerHost",
            dependencies: [
                .product(name: "CmuxNextUiLayerPreview", package: "CmuxNext"),
            ],
            path: "Sources/UiLayerHost"
        ),
        .executableTarget(name: "UiLayerSourceWatcher", path: "Sources/UiLayerSourceWatcher"),
        .testTarget(name: "UiLayerHostTests", dependencies: ["UiLayerHost"]),
    ]
)
