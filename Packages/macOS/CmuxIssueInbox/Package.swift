// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxIssueInbox",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxIssueInbox",
            targets: ["CmuxIssueInbox"]
        ),
    ],
    dependencies: [
        .package(path: "../CmuxFoundation"),
    ],
    targets: [
        .target(
            name: "CmuxIssueInbox",
            dependencies: [
                .product(name: "CmuxFoundation", package: "CmuxFoundation"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxIssueInboxTests",
            dependencies: [
                "CmuxIssueInbox",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
