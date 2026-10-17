// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxArtifactUI",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxArtifactUI",
            targets: ["CmuxArtifactUI"]
        ),
    ],
    dependencies: [
        .package(path: "../../Shared/CMUXMobileCore"),
        .package(path: "../../Shared/CmuxArtifactCore"),
        .package(path: "../CmuxMobileSupport"),
        .package(path: "../CmuxMobileToast"),
        .package(
            url: "https://github.com/raspu/Highlightr.git",
            exact: "2.3.0"
        ),
    ],
    targets: [
        .target(
            name: "CmuxArtifactUI",
            dependencies: [
                "CMUXMobileCore",
                "CmuxArtifactCore",
                "CmuxMobileSupport",
                "CmuxMobileToast",
                .product(name: "Highlightr", package: "Highlightr"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmuxArtifactUITests",
            dependencies: ["CmuxArtifactUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
