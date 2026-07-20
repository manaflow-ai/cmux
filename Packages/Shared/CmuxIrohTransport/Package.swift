// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxIrohTransport",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxIrohTransport",
            targets: ["CmuxIrohTransport"]
        ),
    ],
    dependencies: [
        .package(path: "../CMUXMobileCore"),
        .package(
            url: "https://github.com/manaflow-ai/iroh-ffi.git",
            exact: "1.0.2-cmux.4"
        ),
    ],
    targets: [
        .target(
            name: "CmuxIrohTransport",
            dependencies: [
                "CMUXMobileCore",
                .product(name: "IrohLib", package: "iroh-ffi"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ],
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "CmuxIrohTransportTests",
            dependencies: [
                "CmuxIrohTransport",
                "CMUXMobileCore",
                .product(name: "IrohLib", package: "iroh-ffi"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
