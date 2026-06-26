// swift-tools-version: 6.0

import PackageDescription

// The iPhone iroh dial lane (plans/feat-ios-iroh/DESIGN.md PR 3): a
// CmxByteTransport that dials a Mac by EndpointId over iroh QUIC, wrapping the
// CmuxIrohFFI C surface. It lives in its own package, not in CmuxMobileTransport
// (where CmxNetworkByteTransport lives), because adding the CmuxIrohFFI
// dependency to CmuxMobileTransport trips scripts/check-package-resolved-policy.py:
// a remote-pin-free local binary package does not change a *transitive*
// consumer's Package.resolved originHash, so CmuxMobileShellUI/Package.resolved
// would be unsatisfiable. Only ios/cmuxPackage consumes this package, and its
// lockfile originHash does update.
let package = Package(
    name: "CmuxMobileIrohTransport",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileIrohTransport",
            targets: ["CmuxMobileIrohTransport"]
        ),
    ],
    dependencies: [
        .package(path: "../../Shared/CMUXMobileCore"),
        .package(path: "../../Shared/CmuxIrohFFI"),
    ],
    targets: [
        .target(
            name: "CmuxMobileIrohTransport",
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
            name: "CmuxMobileIrohTransportTests",
            dependencies: [
                "CmuxMobileIrohTransport",
                "CMUXMobileCore",
                .product(name: "CmuxIrohFFI", package: "CmuxIrohFFI"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
