// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxSurfaceCatalogModel",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CmuxSurfaceCatalogModel", targets: ["CmuxSurfaceCatalogModel"])],
    dependencies: [
        .package(path: "../CMUXDebugLog"),
        .package(path: "../CmuxCore")
    ],
    targets: [
        .target(
            name: "CmuxSurfaceCatalogModel",
            dependencies: ["CMUXDebugLog", "CmuxCore"],
            // The files moved out of the app target unchanged; keep its language mode.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "CmuxSurfaceCatalogModelTests", dependencies: ["CmuxSurfaceCatalogModel"])
    ]
)
