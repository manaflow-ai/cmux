// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxVoice",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxVoice",
            targets: ["CmuxVoice"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.4"),
        .package(path: "../CmuxMobileSupport"),
    ],
    targets: [
        .target(
            name: "CmuxVoice",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                "CmuxMobileSupport",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxVoiceTests",
            dependencies: ["CmuxVoice"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
