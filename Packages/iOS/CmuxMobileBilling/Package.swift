// swift-tools-version: 6.0

import PackageDescription

// Billing domain for the phone: StoreKit 2 subscriptions for cmux personal
// plans, verified and applied by the cmux web server
// (`docs/billing/ios-in-app-purchases.md`).
//
// `CmuxMobileBilling` holds the wire contract for `/api/billing/apple/*`, the
// StoreKit seam (`StoreKitClient`) and its live adapter, and the
// `@MainActor @Observable` ``BillingModel`` that sequences purchase, server
// delivery and `finish()`. `CmuxMobileBillingUI` holds the plans screen.
// Tests drive the model through fake StoreKit and API seams, so the package
// builds and tests on macOS without the app host or real StoreKit.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "CmuxMobileBilling",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxMobileBilling", targets: ["CmuxMobileBilling"]),
        .library(name: "CmuxMobileBillingUI", targets: ["CmuxMobileBillingUI"]),
    ],
    dependencies: [
        .package(path: "../../Shared/CMUXMobileCore"),
        .package(path: "../CmuxMobileSupport"),
    ],
    targets: [
        .target(
            name: "CmuxMobileBilling",
            dependencies: ["CMUXMobileCore"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "CmuxMobileBillingUI",
            dependencies: [
                "CmuxMobileBilling",
                "CmuxMobileSupport",
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CmuxMobileBillingTests",
            dependencies: ["CmuxMobileBilling", "CMUXMobileCore"],
            swiftSettings: swiftSettings
        ),
    ]
)
