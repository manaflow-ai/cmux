// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxTerminalImport",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxTerminalImport",
            targets: ["CmuxTerminalImport"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxTerminalImport",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxTerminalImportTests",
            dependencies: ["CmuxTerminalImport"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
