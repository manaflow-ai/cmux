// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMobileTransport",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileTransport",
            targets: ["CmuxMobileTransport"]
        ),
    ],
    dependencies: [
        .package(path: "../CMUXMobileCore"),
        .package(path: "../CmuxIrohFFI"),
    ],
    targets: [
        .target(
            name: "CmuxMobileTransport",
            // CmuxIrohFFI (Rust staticlib C FFI over iroh, Native/cmux-iroh)
            // is linked here so every iOS app build proves the xcframework
            // slice matrix; no code references it until the iroh transport
            // lands (plans/feat-ios-iroh/DESIGN.md PR 3).
            dependencies: [
                "CMUXMobileCore",
                .product(name: "CmuxIrohFFI", package: "CmuxIrohFFI"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxMobileTransportTests",
            dependencies: ["CmuxMobileTransport", "CMUXMobileCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
