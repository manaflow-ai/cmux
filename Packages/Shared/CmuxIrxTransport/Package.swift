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
        .package(path: "../CMUXMobileCore"),
        // Grant claims/verifier and terminal-envelope codecs are consumed as
        // stable data contracts; none of the legacy runtime machinery is used.
        .package(path: "../CmuxIrohTransport"),
        .package(
            url: "https://github.com/manaflow-ai/iroh-ffi.git",
            revision: "51607f3031d9ec1453c258527db5d0735077c631"
        ),
    ],
    targets: [
        .target(
            name: "CmuxIrxTransport",
            dependencies: [
                "CMUXMobileCore",
                "CmuxIrohTransport",
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
            dependencies: [
                "CmuxIrxTransport",
                "CMUXMobileCore",
                "CmuxIrohTransport",
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
