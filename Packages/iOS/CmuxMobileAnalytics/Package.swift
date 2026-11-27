// swift-tools-version: 6.0

import PackageDescription

// Linux lacks Apple-only APIs this package uses: CmuxLinuxCompat supplies
// stand-ins (os Logger, `Darwin.`-qualified libc, String(localized:)).
// Apple builds never see this dependency.
#if os(Linux)
let packageDependencies: [Package.Dependency] = [
    .package(path: "../../Shared/CmuxLinuxCompat"),
]
let targetDependencies: [Target.Dependency] = [
    .product(name: "CmuxLinuxCompat", package: "CmuxLinuxCompat"),
]
#else
let packageDependencies: [Package.Dependency] = []
let targetDependencies: [Target.Dependency] = []
#endif

// `CmuxMobileAnalytics` is the concrete product and operational telemetry
// infrastructure: the fire-and-forget `AnalyticsEmitter` actor, pure
// sessionization and connection-edge throttle logic, and separate HTTP clients
// for PostHog product events and Axiom network outcomes. It conforms to the `AnalyticsEmitting` seam
// declared in `CMUXMobileCore`, so it depends only on that base package and
// Foundation — keeping the package graph an acyclic DAG. Everything it touches
// (the opt-out gate, the clock, `UserDefaults`, reachability, the base URL) is
// injected at construction so the actor is testable without the app.
let package = Package(
    name: "CmuxMobileAnalytics",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileAnalytics",
            targets: ["CmuxMobileAnalytics"]
        ),
    ],
    dependencies: packageDependencies + [
        .package(path: "../../Shared/CMUXMobileCore"),
    ],
    targets: [
        .target(
            name: "CmuxMobileAnalytics",
            dependencies: targetDependencies + [
                "CMUXMobileCore",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxMobileAnalyticsTests",
            dependencies: targetDependencies + [
                "CMUXMobileCore",
                "CmuxMobileAnalytics",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
