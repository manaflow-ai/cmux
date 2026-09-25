// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxSurfaceCatalogModel",
    platforms: [.macOS(.v13)],
    products: [.library(name: "CmuxSurfaceCatalogModel", targets: ["CmuxSurfaceCatalogModel"])],
    dependencies: [
        .package(path: "../CMUXDebugLog"),
        .package(path: "../CmuxCore"),
        .package(path: "../../Shared/CMUXMobileCore")
    ],
    targets: [
        .target(
            name: "CmuxSurfaceCatalogModel",
            dependencies: ["CMUXDebugLog", "CmuxCore", "CMUXMobileCore"],
            // The files moved out of the app target unchanged; keep its language mode.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "CmuxSurfaceCatalogModelTests", dependencies: ["CmuxSurfaceCatalogModel"])
    ]
)
