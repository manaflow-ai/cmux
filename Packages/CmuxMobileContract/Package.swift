// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMobileContract",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileContract",
            targets: ["CmuxMobileContract"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxMobileContract",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxMobileContractTests",
            dependencies: ["CmuxMobileContract"]
        ),
    ]
)
