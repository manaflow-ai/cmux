// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxConversation",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CmuxConversation", targets: ["CmuxConversation"]),
    ],
    targets: [
        .target(
            name: "CmuxConversation",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxConversationTests",
            dependencies: ["CmuxConversation"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
