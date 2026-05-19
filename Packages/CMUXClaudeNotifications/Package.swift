// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CMUXClaudeNotifications",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "CMUXClaudeNotifications",
            targets: ["CMUXClaudeNotifications"]
        ),
    ],
    targets: [
        .target(
            name: "CMUXClaudeNotifications"
        ),
        .testTarget(
            name: "CMUXClaudeNotificationsTests",
            dependencies: ["CMUXClaudeNotifications"]
        ),
    ]
)
