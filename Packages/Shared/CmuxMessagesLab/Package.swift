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
<<<<<<< HEAD
        .package(path: "../CmuxEgress"),
        .package(path: "../CmuxHomeCore"),
        .package(path: "../CmuxHomeRender"),
        .package(path: "../CmuxAgentQuestion"),
        .package(path: "../CmuxAgentBrands"),
        .package(path: "../CmuxSpinner"),
=======
        .package(path: "../CmuxHomeCore"),
        // cmux-classic: approvals answer through `HomeOp.answerQuestion` (Cmux/ChiefRows.swift).
        .package(path: "../CmuxAgentQuestion"),
        .package(path: "../CmuxHomeRender"),
>>>>>>> origin/main
    ],
    targets: [
        .target(
            name: "MessagesLabHome",
<<<<<<< HEAD
            dependencies: [ // sorted: scripts/cmux-next/check-package-dependency-lists.py
                .product(name: "CmuxAgentBrands", package: "CmuxAgentBrands"),
                .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
                .product(name: "CmuxEgress", package: "CmuxEgress"),
                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),
                .product(name: "CmuxHomeRender", package: "CmuxHomeRender"),
                .product(name: "CmuxSpinner", package: "CmuxSpinner"),
=======
            dependencies: [
                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),
                .product(name: "CmuxHomeRender", package: "CmuxHomeRender"),
                .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
>>>>>>> origin/main
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
            name: "MessagesLabHomeTests",
<<<<<<< HEAD
            dependencies: [ // sorted: scripts/cmux-next/check-package-dependency-lists.py
                "MessagesLabHome",
                .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),
                .product(name: "CmuxHomeRender", package: "CmuxHomeRender"),
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
=======
            dependencies: [
                "MessagesLabHome",
                .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),
                .product(name: "CmuxHomeRender", package: "CmuxHomeRender"),
                .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
            ],
            // The motion golden is read from its source path by the harness;
            // exclude the fixture directory from SwiftPM's source scan so it
            // does not become an unhandled-file warning.
            exclude: ["Golden"],
>>>>>>> origin/main
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .define("APPKIT_NATIVE"),
            ]
        ),
    ]
)
