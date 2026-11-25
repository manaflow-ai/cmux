// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxIrxTransport",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxIrxTransport",
            targets: ["CmuxIrxTransport"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxEgress"),
        .package(path: "../CMUXMobileCore"),
        // Grant claims/verifier and terminal-envelope codecs are consumed as
        // stable data contracts; none of the legacy runtime machinery is used.
        .package(path: "../CmuxIrohTransport"),
        .package(
            url: "https://github.com/manaflow-ai/iroh-ffi.git",
            exact: "1.2.0-cmux.1.ios17"
        ),
    ],
    targets: [
        .target(
            name: "CmuxIrxTransport",
            dependencies: [ // sorted: scripts/cmux-next/check-package-dependency-lists.py
                "CMUXMobileCore",
                "CmuxIrohTransport",
                .product(name: "CmuxEgress", package: "CmuxEgress"),
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
            name: "CmuxIrxTransportTests",
            dependencies: [ // sorted: scripts/cmux-next/check-package-dependency-lists.py
                "CMUXMobileCore",
                "CmuxIrohTransport",
                "CmuxIrxTransport",
                .product(name: "IrohLib", package: "iroh-ffi"),
            ],
            resources: [
                .copy("V2/Fixtures"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
