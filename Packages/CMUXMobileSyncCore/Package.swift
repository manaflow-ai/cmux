// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "CMUXMobileSyncCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v10_13),
    ],
    products: [
        .library(
            name: "CMUXMobileSyncCore",
            targets: ["CMUXMobileSyncCore"]
        ),
    ],
    targets: [
        .target(name: "CMUXMobileSyncCore"),
        .testTarget(
            name: "CMUXMobileSyncCoreTests",
            dependencies: ["CMUXMobileSyncCore"]
        ),
    ]
)
