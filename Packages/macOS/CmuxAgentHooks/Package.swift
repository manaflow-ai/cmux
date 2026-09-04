// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxAgentHooks",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxAgentHooks",
            targets: ["CmuxAgentHooks"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxAgentHooks",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxAgentHooksTests",
            dependencies: ["CmuxAgentHooks"]
        ),
    ]
)
