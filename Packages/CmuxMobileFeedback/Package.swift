// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxMobileFeedback",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxMobileFeedback",
            targets: ["CmuxMobileFeedback"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxMobileDiagnostics"),
    ],
    targets: [
        .target(
            name: "CmuxMobileFeedback",
            dependencies: [
                "CmuxMobileDiagnostics",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
