// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxSurfaceCatalogModel",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CmuxSurfaceCatalogModel", targets: ["CmuxSurfaceCatalogModel"])],
    targets: [
        .target(
            name: "CmuxSurfaceCatalogModel",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
