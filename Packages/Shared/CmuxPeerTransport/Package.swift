// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxPeerTransport",
    platforms: [
        .iOS(.v18),
        // Stock iroh-ffi v1.1.0 declares macOS 14.5; the app deployment
        // target moves with it (the zero-fork alternative does not exist).
        .macOS("14.5"),
    ],
    products: [
        .library(
            name: "CmuxPeerTransportCore",
            targets: ["CmuxPeerTransportCore"]
        ),
        .library(
            name: "CmuxPeerTransport",
            targets: ["CmuxPeerTransport"]
        ),
    ],
    dependencies: [
        .package(path: "../CMUXMobileCore"),
        .package(
            url: "https://github.com/n0-computer/iroh-ffi.git",
            exact: "1.1.0"
        ),
    ],
    targets: [
        .target(
            name: "CmuxPeerTransportCore",
            dependencies: [
                "CMUXMobileCore"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .target(
            name: "CmuxPeerTransport",
            dependencies: [
                "CmuxPeerTransportCore",
                "CMUXMobileCore",
                .product(name: "IrohLib", package: "iroh-ffi"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .testTarget(
            name: "CmuxPeerTransportCoreTests",
            dependencies: [
                "CmuxPeerTransportCore",
                "CMUXMobileCore",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxPeerTransportTests",
            dependencies: [
                "CmuxPeerTransport",
                "CmuxPeerTransportCore",
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
