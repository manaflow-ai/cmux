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
        // The egress gate (docs/privacy.md), on every platform the package builds for.
        .package(path: "../CmuxEgress"),
    ],
    targets: [
        .target(
            name: "CMUXMobileCore",
            dependencies: [
                .product(name: "CmuxEgress", package: "CmuxEgress"),
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
