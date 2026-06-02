// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CMUXDeepLinks",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CMUXDeepLinks",
            targets: ["CMUXDeepLinks"]
        ),
    ],
    targets: [
        .target(
            name: "CMUXDeepLinks",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CMUXDeepLinksTests",
            dependencies: ["CMUXDeepLinks"]
        ),
    ]
)
