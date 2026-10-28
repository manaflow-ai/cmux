// swift-tools-version: 6.0

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "CmuxConversation",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CmuxConversationCore", targets: ["CmuxConversationCore"]),
        .library(name: "CmuxConversationUI", targets: ["CmuxConversationUI"]),
        // The bubble outline alone (CoreGraphics), for surfaces that draw a
        // transcript without the chat UI (the notification content extension).
        .library(name: "CmuxConversationGeometry", targets: ["CmuxConversationGeometry"]),
        .library(name: "CmuxConversationMacUI", targets: ["CmuxConversationMacUI"]),
    ],
    dependencies: [
        // The composer's keyboard dock (MobileKeyboardDock), iOS only.
        .package(path: "../CmuxMobileSupport"),
    ],
    targets: [
        .target(
            name: "CmuxConversationCore",
            resources: [.process("Resources")],
            swiftSettings: swiftSettings
        ),
        .target(name: "CmuxConversationGeometry", dependencies: ["CmuxConversationCore"], swiftSettings: swiftSettings),
        .target(
            name: "CmuxConversationTranslation",
            dependencies: ["CmuxConversationCore"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "CmuxConversationUI",
            dependencies: [
                "CmuxConversationCore", "CmuxConversationGeometry", "CmuxConversationTranslation",
                .product(name: "CmuxMobileSupport", package: "CmuxMobileSupport", condition: .when(platforms: [.iOS])),
            ],
            resources: [.process("Resources")],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "CmuxConversationMacUI",
            dependencies: ["CmuxConversationCore", "CmuxConversationGeometry", "CmuxConversationTranslation"],
            resources: [.process("Resources")],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "CmuxConversationLabMac",
            dependencies: ["CmuxConversationMacUI"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CmuxConversationGeometryTests",
            dependencies: ["CmuxConversationGeometry"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CmuxConversationCoreTests",
            dependencies: ["CmuxConversationCore", "CmuxConversationGeometry"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CmuxConversationMacUITests",
            dependencies: ["CmuxConversationMacUI", "CmuxConversationCore"],
            swiftSettings: swiftSettings
        ),
    ]
)
