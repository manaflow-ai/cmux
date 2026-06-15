// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxBrowserFind",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxBrowserFind",
            targets: ["CmuxBrowserFind"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxBrowserFind",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxBrowserFindTests",
            dependencies: ["CmuxBrowserFind"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
