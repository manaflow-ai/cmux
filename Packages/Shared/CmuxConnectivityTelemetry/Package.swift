// swift-tools-version: 6.0

import PackageDescription

// Connectivity observability for cmux NEXT on the Mac and the iPhone: one event shape for
// every connection step (phone link, pairing, the Mac's cmux link and phone host, the agent
// hub), and one policy that decides what each audience records. The cmux team (a signed-in
// @manaflow.ai or @cmux.com account) gets every event with its free-text detail; everyone else
// gets fixed-vocabulary fields only, sampled and budgeted. Pure Foundation, no SDK: each app
// adds its own sinks (the on-device journal here, Sentry on the Mac).
let package = Package(
    name: "CmuxConnectivityTelemetry",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxConnectivityTelemetry", targets: ["CmuxConnectivityTelemetry"]),
    ],
    targets: [
        .target(
            name: "CmuxConnectivityTelemetry",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxConnectivityTelemetryTests",
            dependencies: ["CmuxConnectivityTelemetry"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
