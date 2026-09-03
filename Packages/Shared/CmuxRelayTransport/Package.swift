// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxRelayTransport",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxRelayTransport",
            targets: ["CmuxRelayTransport"]
        ),
    ],
    dependencies: [
        .package(path: "../CMUXMobileCore"),
    ],
    targets: [
        .target(
            name: "CmuxRelayTransport",
            dependencies: [
                .product(name: "CMUXMobileCore", package: "CMUXMobileCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxRelayTransportTests",
            dependencies: ["CmuxRelayTransport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
