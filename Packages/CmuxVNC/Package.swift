// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxVNC",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxVNC",
            targets: ["CmuxVNC"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxVNC",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "CmuxVNCTests",
            dependencies: ["CmuxVNC"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
    ]
)
