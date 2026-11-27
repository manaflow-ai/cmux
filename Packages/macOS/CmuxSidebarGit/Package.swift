// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxSidebarGit",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxSidebarGit",
            targets: ["CmuxSidebarGit"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxGit"),
        .package(path: "../CmuxFoundation"),
    ],
    targets: [
        .target(
            name: "CmuxSidebarGit",
            dependencies: [
                .product(name: "CmuxGit", package: "CmuxGit"),
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxSidebarGitTests",
            dependencies: [
                "CmuxSidebarGit",
                .product(name: "CmuxGit", package: "CmuxGit"),
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
