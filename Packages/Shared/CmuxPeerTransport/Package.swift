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
        .package(path: "../CMUXMobileCore")
    ],
    targets: [
        // Upstream n0-computer/iroh-ffi v1.1.0 binaries, rewrapped
        // framework-style by scripts/ensure-iroh-xcframework.sh (run it once
        // per checkout; setup.sh and the CI lanes do this automatically).
        .binaryTarget(
            name: "Iroh",
            path: "../../../IrohFFI.xcframework"
        ),
        // Unmodified generated Swift bindings vendored from the same tag;
        // see Sources/IrohLib/README.md.
        .target(
            name: "IrohLib",
            dependencies: ["Iroh"],
            // Upstream builds these generated bindings with swift-tools 5.9
            // semantics; Swift 6 strict concurrency rejects the generated
            // uniffi continuation plumbing.
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("Network"),
                .linkedFramework("CoreWLAN", .when(platforms: [.macOS])),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
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
                "IrohLib",
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
                "IrohLib",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
