// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxCloudTui",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CmuxCloudTui", targets: ["CmuxCloudTui"])],
    dependencies: [
        .package(path: "../CmuxCloudImagePaste"),
        .package(path: "../CmuxFoundation"),
        .package(path: "../CmuxSurfaceCatalogModel"),
        .package(path: "../CmuxTerminal")
    ],
    targets: [
        .target(
            name: "CmuxCloudTui",
            dependencies: ["CmuxCloudImagePaste", "CmuxFoundation", "CmuxSurfaceCatalogModel", "CmuxTerminal"],
            // The files moved out of the app target unchanged; keep its language mode.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "CmuxCloudTuiTests", dependencies: ["CmuxCloudTui"])
    ]
)
