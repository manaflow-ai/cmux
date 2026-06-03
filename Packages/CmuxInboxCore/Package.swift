// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxInboxCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxInboxCore",
            targets: ["CmuxInboxCore"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxMobileContract"),
    ],
    targets: [
        .target(
            name: "CmuxInboxCore",
            dependencies: [
                .product(name: "CmuxMobileContract", package: "CmuxMobileContract"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxInboxCoreTests",
            dependencies: ["CmuxInboxCore"]
        ),
    ]
)
