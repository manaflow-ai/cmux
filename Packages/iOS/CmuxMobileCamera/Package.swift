// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMobileCamera",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileCamera",
            targets: ["CmuxMobileCamera"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxMobileCamera",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxMobileCameraTests",
            dependencies: ["CmuxMobileCamera"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
