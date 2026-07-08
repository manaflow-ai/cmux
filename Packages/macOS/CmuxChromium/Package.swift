// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxChromium",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxChromium",
            targets: ["CmuxChromium"]
        ),
    ],
    targets: [
        .target(
            name: "COwlFreshRuntime"
        ),
        .target(
            name: "CmuxChromium",
            dependencies: ["COwlFreshRuntime"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxChromiumTests",
            dependencies: ["CmuxChromium", "COwlFreshRuntime"]
        ),
    ]
)
