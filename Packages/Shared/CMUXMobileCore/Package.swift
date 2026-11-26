// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CMUXMobileCore",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CMUXMobileCore",
            targets: ["CMUXMobileCore"]
        ),
    ],
    dependencies: [
        // The egress gate (docs/privacy.md): Apple platforms only, where the app runs.
        .package(path: "../CmuxEgress"),
    ],
    targets: [
        .target(
            name: "CMUXMobileCore",
            dependencies: [
                .product(name: "CmuxEgress", package: "CmuxEgress", condition: .when(platforms: [.macOS, .iOS])),
            ],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CMUXMobileCoreTests",
            dependencies: ["CMUXMobileCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
