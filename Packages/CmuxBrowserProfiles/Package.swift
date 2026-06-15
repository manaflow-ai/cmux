// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxBrowserProfiles",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxBrowserProfiles",
            targets: ["CmuxBrowserProfiles"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxBrowserProfiles",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxBrowserProfilesTests",
            dependencies: ["CmuxBrowserProfiles"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
