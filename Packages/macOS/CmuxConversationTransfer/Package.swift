// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxConversationTransfer",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxConversationTransfer",
            targets: ["CmuxConversationTransfer"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxConversationTransfer",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxConversationTransferTests",
            dependencies: ["CmuxConversationTransfer"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
