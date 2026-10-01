// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxAcpmux",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CmuxAcpmux", targets: ["CmuxAcpmux"]),
    ],
    dependencies: [
        .package(path: "../CmuxConversation"),
    ],
    targets: [
        .target(
            name: "CmuxAcpmux",
            dependencies: ["CmuxConversation"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxAcpmuxTests",
            dependencies: ["CmuxAcpmux", "CmuxConversation"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
