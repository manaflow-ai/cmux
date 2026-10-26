// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMobileSupport",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileSupport",
            targets: ["CmuxMobileSupport"]
        ),
    ],
    dependencies: [
        // The portable Mutex the keyboard observers and the dictation audio engine use (p10-stability-172).
        .package(path: "../../Shared/CmuxSafeConcurrency"),
    ],
    targets: [
        .target(
            name: "CmuxMobileSupport",
            dependencies: [.product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxMobileSupportTests",
            dependencies: ["CmuxMobileSupport"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
