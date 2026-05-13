// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "CMUXDesktopPrototypeFeature",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "CMUXDesktopPrototypeFeature",
            targets: ["CMUXDesktopPrototypeFeature"]
        ),
    ],
    targets: [
        .target(
            name: "CMUXDesktopPrototypeFeature",
            resources: [.process("Resources")]
        ),
    ]
)
