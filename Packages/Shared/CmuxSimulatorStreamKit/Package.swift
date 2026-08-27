// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxSimulatorStreamKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxSimulatorStreamKit",
            targets: ["CmuxSimulatorStreamKit"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxSimulatorStreamKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxSimulatorStreamKitTests",
            dependencies: ["CmuxSimulatorStreamKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
