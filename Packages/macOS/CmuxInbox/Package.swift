// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxInbox",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxInbox",
            targets: ["CmuxInbox"]
        ),
    ],
    targets: [
        .target(
            name: "CmuxInbox",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "CmuxInboxTests",
            dependencies: ["CmuxInbox"]
        ),
    ]
)
