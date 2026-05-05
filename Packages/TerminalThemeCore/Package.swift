// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TerminalThemeCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "TerminalThemeCore",
            targets: ["TerminalThemeCore"]
        ),
    ],
    targets: [
        .target(
            name: "TerminalThemeCore"
        ),
    ]
)
