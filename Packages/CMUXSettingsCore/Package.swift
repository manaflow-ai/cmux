// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CMUXSettingsCore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CMUXSettingsCore",
            targets: ["CMUXSettingsCore"]
        ),
    ],
    targets: [
        .target(
            name: "CMUXSettingsCore"
        ),
    ]
)
