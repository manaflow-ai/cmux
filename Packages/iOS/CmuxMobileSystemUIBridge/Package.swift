// swift-tools-version: 6.0

import PackageDescription

// The app's seam to CmuxMobileSystemUI.framework, the embedded, unlinked
// framework that holds every use of AuthenticationServices, SafariServices,
// StoreKit, PhotosUI and QuickLook (cmux-next-ios/SystemUI). Linking any of
// those frameworks costs about 1.55 s before main on a cold launch, all of
// them about 2.1 s; this module imports none of them. It holds the
// Objective-C contract (`SystemUIContract.swift`, compiled into the framework
// too) and the loader that opens the framework on first use.
let package = Package(
    name: "CmuxMobileSystemUIBridge",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileSystemUIBridge",
            targets: ["CmuxMobileSystemUIBridge"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxMobileSystemUIBridge",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
