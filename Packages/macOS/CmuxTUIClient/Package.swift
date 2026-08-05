// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxTUIClient",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CmuxTUIClient", targets: ["CmuxTUIClient"]),
    ],
    targets: [
        .target(
            name: "CmuxTUIClient",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxTUIClientTests",
            dependencies: ["CmuxTUIClient"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
