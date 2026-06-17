// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CMUXAgentContinuation",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CMUXAgentContinuation",
            targets: ["CMUXAgentContinuation"]
        ),
    ],
    targets: [
        .target(
            name: "CMUXAgentContinuation",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CMUXAgentContinuationTests",
            dependencies: ["CMUXAgentContinuation"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
