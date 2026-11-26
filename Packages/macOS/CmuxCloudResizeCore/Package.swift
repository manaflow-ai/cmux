// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxCloudResizeCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CmuxCloudResizeCore", targets: ["CmuxCloudResizeCore"])
    ],
    targets: [
        .target(
            name: "CmuxCloudResizeCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
