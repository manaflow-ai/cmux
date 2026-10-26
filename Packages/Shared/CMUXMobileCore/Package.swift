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
        .package(path: "../CmuxFuzzSupport"),
    ],
    targets: [
        .target(
            name: "CMUXMobileCore",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CMUXMobileCoreTests",
            dependencies: ["CMUXMobileCore", .product(name: "CmuxFuzzSupport", package: "CmuxFuzzSupport")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
