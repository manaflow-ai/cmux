// swift-tools-version: 6.0

import Foundation
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
//
// The same tests run on Linux (scripts/ci/swift-linux-packages.txt): the
// model, the wire contract and the HTTP client need only Foundation. The
// plans screen is SwiftUI and its CmuxMobileSupport dependency is UIKit, so
// the Linux package jobs, which set CMUX_SWIFTPM_TARGET_LINUX, leave that
// target out. A build for an Apple platform on a Linux host keeps it.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
]

#if os(Linux)
let targetsLinux = ProcessInfo.processInfo.environment["CMUX_SWIFTPM_TARGET_LINUX"] == "1"
#else
let targetsLinux = false
#endif

let package = Package(
    name: "CmuxMobileBilling",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxMobileBilling", targets: ["CmuxMobileBilling"]),
    ] + (targetsLinux ? [] : [
        .library(name: "CmuxMobileBillingUI", targets: ["CmuxMobileBillingUI"]),
    ]),
    dependencies: [
        .package(path: "../../Shared/CMUXMobileCore"),
    ] + (targetsLinux ? [] : [
        // StoreKit through CmuxMobileSystemUI.framework (iOS): linked, StoreKit costs the
        // app about 1.55 s before main, so LiveStoreKitClient reaches it through the bridge.
        .package(path: "../CmuxMobileSystemUIBridge"),
        .package(path: "../CmuxMobileSupport"),
        .package(path: "../../Shared/CmuxSpinner"),
    ]),
    targets: [
        .target(
            name: "CmuxMobileBilling",
            dependencies: ["CMUXMobileCore"] + (targetsLinux ? [] : [
                .product(name: "CmuxMobileSystemUIBridge", package: "CmuxMobileSystemUIBridge", condition: .when(platforms: [.iOS])),
            ]),
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CmuxMobileBillingTests",
            dependencies: ["CmuxMobileBilling", "CMUXMobileCore"],
            swiftSettings: swiftSettings
        ),
    ] + (targetsLinux ? [] : [
        .target(
            name: "CmuxMobileBillingUI",
            dependencies: [
                "CmuxMobileBilling",
                "CmuxMobileSupport",
                .product(name: "CmuxMobileSystemUIBridge", package: "CmuxMobileSystemUIBridge", condition: .when(platforms: [.iOS])),
                .product(name: "CmuxSpinner", package: "CmuxSpinner"),
            ],
            swiftSettings: swiftSettings
        ),
    ])
)
