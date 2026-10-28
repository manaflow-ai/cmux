// swift-tools-version: 6.2

import PackageDescription

// The MessagesLabAppKitNative transcript, vendored (not rewritten) for the
// cmux-next Mac Home tab. README.md: what is vendored, the pin (vendor.tsv),
// the blocker patches (Patches/) and scripts/cmux-next/sync-messageslab.sh.
// Upstream builds with Swift 5, minimal strict concurrency and the
// APPKIT_NATIVE condition (appkit-native/project.yml); this target keeps
// all three so the files compile unchanged.
let package = Package(
    name: "CmuxMessagesLab",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "MessagesLabHome", targets: ["MessagesLabHome"]),
        // MessagesLab's conversation list (appkit-native/SIDEBAR.md, the v1 seam): its own
        // module because its ConversationID and ConversationSummary are not CmuxHomeCore's.
        .library(name: "MessagesLabSidebar", targets: ["MessagesLabSidebar"]),
    ],
    dependencies: [
        .package(path: "../CmuxHomeCore"),
        .package(path: "../CmuxHomeRender"),
        .package(path: "../CmuxFuzzSupport"),
        // The portable Mutex the transcript's shared caches live in.
        .package(path: "../CmuxSafeConcurrency"),
    ],
    targets: [
        .target(
            name: "MessagesLabHome",
            dependencies: [
                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),
                .product(name: "CmuxHomeRender", package: "CmuxHomeRender"),
                .product(name: "CmuxSafeConcurrency", package: "CmuxSafeConcurrency"),
            ],
            resources: [
                .process("Resources/Localizable.xcstrings"),
                .process("Resources/AppKitNative.xcstrings"),
                .process("Resources/CmuxHome.xcstrings"),
                .copy("Resources/springs.json"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .define("APPKIT_NATIVE"),
            ]
        ),
        .target(
            name: "MessagesLabSidebar",
            resources: [
                .process("Resources/SidebarLocalizable.xcstrings"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .define("APPKIT_NATIVE"),
            ]
        ),
        .testTarget(
            name: "MessagesLabHomeTests",
            dependencies: [
                "MessagesLabHome",
                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),
                .product(name: "CmuxHomeRender", package: "CmuxHomeRender"),
                .product(name: "CmuxFuzzSupport", package: "CmuxFuzzSupport"),
            ],
            // MessagesLab's shared/conversation.json (vendor.tsv), read by path.
            exclude: ["Fixtures"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .define("APPKIT_NATIVE"),
            ]
        ),
        .testTarget(
            name: "MessagesLabSidebarTests",
            dependencies: ["MessagesLabSidebar"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .define("APPKIT_NATIVE"),
            ]
        ),
    ]
)

// BEGIN apply-stability-settings.py: generated from scripts/cmux-next/stability-settings.json; do not edit.
// p10 stability settings per target (plans/cmux-next/chrome-parity/p10-stability.md C.5): add a row to
// stability-settings.json and run the lander instead of editing this block or a target's settings.
let stabilitySettingGroups: [(targets: [String], settings: [SwiftSetting])] = [
    (
        targets: [
            "MessagesLabHome",
            "MessagesLabHomeTests",
            "MessagesLabSidebar",
            "MessagesLabSidebarTests",
        ],
        settings: [
            .strictMemorySafety(),
        ]
    ),
]
for group in stabilitySettingGroups {
    for target in package.targets where group.targets.contains(target.name) {
        target.swiftSettings = (target.swiftSettings ?? []) + group.settings
    }
}
// END apply-stability-settings.py
