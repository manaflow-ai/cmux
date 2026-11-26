// swift-tools-version: 6.0

import PackageDescription

// The classic iPhone app's (ios/CmuxiOS) push registration: the APNs device-token
// sync with /api/device-tokens. It lived in CmuxAuthRuntime, which the NEXT Mac app
// links, though only ios/CmuxiOS ever builds a PushRegistrationService; here only
// ios/CmuxiOS links it.
let package = Package(
    name: "CmuxPushRegistration",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxPushRegistration",
            targets: ["CmuxPushRegistration"]
        ),
    ],
    dependencies: [
        .package(path: "../../Shared/CmuxAuthRuntime"),
    ],
    targets: [
        .target(
            name: "CmuxPushRegistration",
            dependencies: [
                .product(name: "CmuxAuthRuntime", package: "CmuxAuthRuntime"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxPushRegistrationTests",
            dependencies: [
                "CmuxPushRegistration",
                .product(name: "CmuxAuthRuntime", package: "CmuxAuthRuntime"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
