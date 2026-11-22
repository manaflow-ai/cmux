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
        .macOS(.v26),
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
    ],
    targets: [
        .target(
            name: "MessagesLabHome",
            dependencies: [
                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),
                .product(name: "CmuxHomeRender", package: "CmuxHomeRender"),
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
                .swiftLanguageMode(.v5),
                .define("APPKIT_NATIVE"),
            ]
        ),
        .testTarget(
            name: "MessagesLabSidebarTests",
            dependencies: ["MessagesLabSidebar"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .define("APPKIT_NATIVE"),
            ]
        ),
        .testTarget(
            name: "MessagesLabHomeTests",
            dependencies: [
                "MessagesLabHome",
                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .define("APPKIT_NATIVE"),
            ]
        ),
    ]
)
