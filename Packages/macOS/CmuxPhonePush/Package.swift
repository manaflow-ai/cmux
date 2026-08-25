// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxPhonePush",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CmuxPhonePush", targets: ["CmuxPhonePush"]),
    ],
    dependencies: [
        .package(path: "../../Shared/CmuxAuthRuntime"),
    ],
    targets: [
        .target(
            name: "CmuxPhonePush",
            dependencies: ["CmuxAuthRuntime"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxPhonePushTests",
            dependencies: ["CmuxPhonePush"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
