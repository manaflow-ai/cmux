// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxMobileAgent",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CmuxMobileAgent", targets: ["CmuxMobileAgent"]),
    ],
    dependencies: [
        .package(path: "../../Shared/CmuxConversation"),
    ],
    targets: [
        .target(
            name: "CmuxMobileAgent",
            dependencies: ["CmuxConversation"],
            resources: [.process("Resources")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
