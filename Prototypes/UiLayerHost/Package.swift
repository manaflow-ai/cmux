// swift-tools-version: 6.2

import PackageDescription

// Debug-only host for iterating on cmux-next chrome against an exported,
// read-only projection. It intentionally has no dependency on the app target.
let package = Package(
    name: "UiLayerHost",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "cmux-ui-layer", targets: ["UiLayerHost"])],
    targets: [
        .executableTarget(name: "UiLayerHost", path: "Sources/UiLayerHost"),
        .testTarget(name: "UiLayerHostTests", dependencies: ["UiLayerHost"]),
    ]
)
