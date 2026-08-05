// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CmuxAgentChatUI",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxAgentChatUI",
            targets: ["CmuxAgentChatUI"]
        ),
    ],
    dependencies: [
        .package(path: "../../Shared/CMUXMobileCore"),
        .package(path: "../../Shared/CmuxAgentChat"),
        .package(path: "../CmuxMobileSupport"),
        .package(path: "../CmuxMobileToast"),
        .package(
            url: "https://github.com/raspu/Highlightr.git",
            exact: "2.3.0"
        ),
    ],
    targets: [
        .target(
            name: "CmuxAgentChatUI",
            dependencies: [
                "CMUXMobileCore",
                "CmuxAgentChat",
                "CmuxMobileSupport",
                "CmuxMobileToast",
                .product(name: "Highlightr", package: "Highlightr"),
            ],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6), .defaultIsolation(MainActor.self), .enableUpcomingFeature("InferIsolatedConformances"), .enableUpcomingFeature("NonisolatedNonsendingByDefault")]
        ),
        .testTarget(
            name: "CmuxAgentChatUITests",
            dependencies: ["CmuxAgentChatUI", "CmuxMobileToast"],
            swiftSettings: [.swiftLanguageMode(.v6), .defaultIsolation(MainActor.self), .enableUpcomingFeature("InferIsolatedConformances"), .enableUpcomingFeature("NonisolatedNonsendingByDefault")]
        ),
    ]
)
