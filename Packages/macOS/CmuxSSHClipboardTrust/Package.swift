// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxSSHClipboardTrust",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CmuxSSHClipboardTrust", targets: ["CmuxSSHClipboardTrust"])],
    dependencies: [.package(path: "../CmuxSurfaceCatalogModel")],
    targets: [
        .target(
            name: "CmuxSSHClipboardTrust",
            dependencies: ["CmuxSurfaceCatalogModel"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CmuxSSHClipboardTrustTests",
            dependencies: ["CmuxSSHClipboardTrust", "CmuxSurfaceCatalogModel"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
