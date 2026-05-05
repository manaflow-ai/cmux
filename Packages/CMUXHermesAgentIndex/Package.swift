// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CMUXHermesAgentIndex",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "CMUXHermesAgentIndex",
            targets: ["CMUXHermesAgentIndex"]
        ),
    ],
    targets: [
        .target(
            name: "CMUXHermesAgentIndex",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "CMUXHermesAgentIndexTests",
            dependencies: ["CMUXHermesAgentIndex"],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)
