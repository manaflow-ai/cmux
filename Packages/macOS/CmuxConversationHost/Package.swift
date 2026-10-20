// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxConversationHost",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CmuxConversationHost", targets: ["CmuxConversationHost"])],
    dependencies: [
        .package(path: "../../Shared/CmuxConversation"),
    ],
    targets: [
        .target(
            name: "CmuxConversationHost",
            dependencies: [.product(name: "CmuxConversation", package: "CmuxConversation")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxConversationHostTests",
            dependencies: ["CmuxConversationHost", .product(name: "CmuxConversation", package: "CmuxConversation")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
