// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CMUXMobileCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CMUXMobileCore",
            targets: ["CMUXMobileCore"]
        ),
    ],
    targets: [
        .target(
            name: "CMUXMobileCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CMUXMobileCoreTests",
            dependencies: ["CMUXMobileCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
