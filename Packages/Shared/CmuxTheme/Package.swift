// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxTheme",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxTheme",
            targets: ["CmuxTheme"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxTheme",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
