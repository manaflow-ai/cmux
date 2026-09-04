// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxTopMemory",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxTopMemory",
            targets: ["CmuxTopMemory"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxTopMemory",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxTopMemoryTests",
            dependencies: ["CmuxTopMemory"]
        ),
    ]
)
