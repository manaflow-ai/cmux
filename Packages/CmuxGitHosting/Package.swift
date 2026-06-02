// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxGitHosting",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxGitHosting",
            targets: ["CmuxGitHosting"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxProcess"),
    ],
    targets: [
        .target(
            name: "CmuxGitHosting",
            dependencies: [
                .product(name: "CmuxProcess", package: "CmuxProcess"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxGitHostingTests",
            dependencies: [
                "CmuxGitHosting",
                .product(name: "CmuxProcess", package: "CmuxProcess"),
            ]
        ),
    ]
)
