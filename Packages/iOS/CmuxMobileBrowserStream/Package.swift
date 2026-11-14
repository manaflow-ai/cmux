// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMobileBrowserStream",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxMobileBrowserStream", targets: ["CmuxMobileBrowserStream"]),
    ],
    dependencies: [
        .package(path: "../../Shared/CMUXMobileCore"),
        .package(path: "../CmuxMobileSupport"),
    ],
    targets: [
        .target(
            name: "CmuxMobileBrowserStream",
            dependencies: ["CMUXMobileCore", "CmuxMobileSupport"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxMobileBrowserStreamTests",
            dependencies: ["CmuxMobileBrowserStream", "CMUXMobileCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
