// swift-tools-version: 6.0

import PackageDescription

// `CmuxMobileAnalytics` is the concrete analytics infrastructure: the
// fire-and-forget `AnalyticsEmitter` actor, the pure sessionization and
// connection-edge throttle logic, and the HTTP capture client that posts batches
// to the cmux web analytics proxy. It conforms to the `AnalyticsEmitting` seam
// declared in `CMUXMobileCore`, so it depends only on that base package and
// Foundation — keeping the package graph an acyclic DAG. Everything it touches
// (the opt-out gate, the clock, `UserDefaults`, reachability, the base URL) is
// injected at construction so the actor is testable without the app.
let package = Package(
    name: "CmuxMobileAnalytics",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileAnalytics",
            targets: ["CmuxMobileAnalytics"]
        ),
    ],
    dependencies: [
        .package(path: "../../Shared/CMUXMobileCore"),
    ],
    targets: [
        .target(
            name: "CmuxMobileAnalytics",
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
            name: "CmuxMobileAnalyticsTests",
            dependencies: ["CmuxMobileAnalytics"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
