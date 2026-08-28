// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxDotTransport",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxDotTransport",
            targets: ["CmuxDotTransport"]
        ),
    ],
    dependencies: [
        // Byte-transport protocols and the mobile dialect frame codecs are
        // consumed as stable data contracts. Deliberately NO iroh dependency:
        // this package is the Durable Object relay transport that replaces it.
        .package(path: "../CMUXMobileCore"),
    ],
    targets: [
        .target(
            name: "CmuxDotTransport",
            dependencies: [
                "CMUXMobileCore",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxDotTransportTests",
            dependencies: ["CmuxDotTransport"]
        ),
    ]
)
