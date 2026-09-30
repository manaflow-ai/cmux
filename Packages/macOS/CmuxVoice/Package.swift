// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxVoice",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxVoice",
            targets: ["CmuxVoice"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxVoice",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxVoiceTests",
            dependencies: [
                "CmuxVoice",
            ]
        ),
    ]
)
