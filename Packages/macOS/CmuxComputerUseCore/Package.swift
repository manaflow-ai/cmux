// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxComputerUseCore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxComputerUseCore",
            targets: ["CmuxComputerUseCore"]
        ),
    ],
    targets: [
        .target(name: "CmuxComputerUseCore"),
    ]
)
