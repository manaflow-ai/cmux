// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxBrowserEngine",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxBrowserEngine",
            targets: ["CmuxBrowserEngine"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxBrowserEngine"
        ),
        .testTarget(
            name: "CmuxBrowserEngineTests",
            dependencies: ["CmuxBrowserEngine"]
        ),
    ]
)
