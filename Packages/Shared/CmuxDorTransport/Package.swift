// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxDorTransport",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxDorTransport",
            targets: ["CmuxDorTransport"]
        ),
    ],
    // Deliberately dependency-free (Foundation + CryptoKit only): this is the
    // Durable Object relay transport that REPLACES iroh, and the app glue owns
    // every adaptation to cmux seam protocols.
    targets: [
        .target(
            name: "CmuxDorTransport",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxDorTransportTests",
            dependencies: ["CmuxDorTransport"]
        ),
    ]
)
