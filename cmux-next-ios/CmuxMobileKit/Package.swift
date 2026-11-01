// swift-tools-version: 6.2

import PackageDescription

// CmuxMobileKit: every module of the cmux-next-ios app. See ../PLAN.md.
let package = Package(
    name: "CmuxMobileKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "CmuxMobileShell", targets: ["CmuxMobileShell"]),
        .library(name: "CmuxMobileModel", targets: ["CmuxMobileModel"]),
        .library(name: "CmuxMobileDesign", targets: ["CmuxMobileDesign"]),
        .library(name: "CmuxMobileTransport", targets: ["CmuxMobileTransport"]),
        .library(name: "CmuxMobileMarkdown", targets: ["CmuxMobileMarkdown"]),
        .library(name: "CmuxMobileDiff", targets: ["CmuxMobileDiff"]),
        .library(name: "CmuxMobileAgentChat", targets: ["CmuxMobileAgentChat"]),
        .library(name: "CmuxMobileFeed", targets: ["CmuxMobileFeed"]),
        .library(name: "CmuxMobileAuth", targets: ["CmuxMobileAuth"]),
        .library(name: "CmuxMobileOnboarding", targets: ["CmuxMobileOnboarding"]),
        .library(name: "CmuxMobileSettings", targets: ["CmuxMobileSettings"]),
        .library(name: "CmuxMobileWorkspaces", targets: ["CmuxMobileWorkspaces"]),
        .library(name: "CmuxMobileChief", targets: ["CmuxMobileChief"]),
        .library(name: "CmuxMobileTerminal", targets: ["CmuxMobileTerminal"]),
        .library(name: "CmuxMobileLive", targets: ["CmuxMobileLive"]),
        .library(name: "CmuxMobileArtifacts", targets: ["CmuxMobileArtifacts"]),
        .library(name: "CmuxMobileBrowserStream", targets: ["CmuxMobileBrowserStream"]),
        .library(name: "CmuxMobileVoice", targets: ["CmuxMobileVoice"]),
        .library(name: "CmuxMobileRealtime", targets: ["CmuxMobileRealtime"]),
        .library(name: "CmuxMobileNotifications", targets: ["CmuxMobileNotifications"]),
        .library(name: "CmuxMobileScreenSharing", targets: ["CmuxMobileScreenSharing"]),
    ],
    dependencies: [
        .package(path: "../../Packages/Shared/CmuxGhosttyKit"),
        .package(path: "../../Packages/Shared/CmuxAgentQuestion"),
        // Shared Stack Auth runtime (used as-is; do not modify from here).
        .package(path: "../../Packages/Shared/CmuxAuthRuntime"),
        .package(path: "../../Packages/Shared/CMUXAuthCore"),
        .package(path: "../../vendor/stack-auth-swift-sdk-prerelease"),
        // Safari-style tabs (workspaces) and the Messages-style conversation (Chief).
        .package(path: "../../Packages/iOS/CmuxTabsKit"),
        // The classic app's composer dictation, shared as-is (terminal composer mic).
        .package(path: "../../Packages/iOS/CmuxMobileSupport"),
        .package(path: "../../Packages/iOS/CmuxConversation"),
        // The agents' brand marks (Claude, Codex), shared with the Mac app.
        .package(path: "../../Packages/Shared/CmuxAgentBrands"),
        // The Action Button call flow (plans/cmux-next/ios-action-button-DESIGN.md).
        .package(path: "../../Packages/Shared/CmuxChiefVoiceCore"),
        // Screen Sharing: this iPhone as a device of the device hub, and the Mac screen viewer
        // (CmuxScreenKit, over CmuxVNCWebRTC, which also provides the app's one WebRTC.framework).
        .package(path: "../../Packages/Shared/CmuxDeviceHub"),
        .package(path: "../../Packages/Shared/CmuxScreenKit"),
        .package(path: "../../Packages/Shared/CmuxVNCWebRTC"),
    ],
    targets: [
        .target(name: "CmuxMobileDesign", resources: [.process("Resources")]),
        // Push payloads, notification buttons, the App Group outbox and chat
        // snapshots: Foundation and UserNotifications only, so the notification
        // extensions link it without the app's modules (verify/rich-push.md).
        .target(name: "CmuxMobileNotifications"),
        .target(name: "CmuxMobileModel", resources: [.process("Resources")]),
        .binaryTarget(name: "CmuxMobileLinkFFIFFI", path: "Frameworks/CmuxMobileLinkFFI.xcframework"),
        .target(
            name: "CmuxMobileLinkFFI",
            dependencies: [.target(name: "CmuxMobileLinkFFIFFI", condition: .when(platforms: [.iOS]))],
            path: "Sources/CmuxMobileLinkFFI",
            // uniffi's generated Swift is not Swift 6 concurrency-clean.
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("SystemConfiguration")]
        ),
        .target(name: "CmuxMobileTransport", dependencies: [.target(name: "CmuxMobileLinkFFI", condition: .when(platforms: [.iOS]))]),
        // Markdown: native block renderer for transcripts, WKWebView renderer (pooled) for the Feed and math.
        .target(name: "CmuxMobileMarkdown", dependencies: ["CmuxMobileDesign", "CmuxMobileModel"], resources: [.copy("Resources/web")]),
        // Diff model (line + word diff, unified parser) and the GitHub-mobile-style viewer.
        .target(name: "CmuxMobileDiff", dependencies: ["CmuxMobileDesign"]),
        // Session artifacts: the reference model and extractor, sources (mock, inline, the Mac's `file`
        // link service), the browser and previews. Shared by the terminal and agent sessions.
        .target(name: "CmuxMobileArtifacts", dependencies: ["CmuxMobileDesign", "CmuxMobileTransport"]),
        // ACP agent session model, AgentSessionSource (mock now, acpmux over the link later), chat screen.
        .target(name: "CmuxMobileAgentChat", dependencies: [
            "CmuxMobileDesign", "CmuxMobileModel", "CmuxMobileMarkdown", "CmuxMobileDiff", "CmuxMobileArtifacts", "CmuxMobileTransport",
            .product(name: "CmuxAgentBrands", package: "CmuxAgentBrands"),
            .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
            .product(name: "CmuxMobileSupport", package: "CmuxMobileSupport", condition: .when(platforms: [.iOS])),
        ]),
        .target(name: "CmuxMobileFeed", dependencies: [
            "CmuxMobileDesign", "CmuxMobileModel", "CmuxMobileMarkdown", "CmuxMobileAgentChat",
            .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
        ]),
        .target(
            name: "CmuxMobileAuth",
            dependencies: [
                "CmuxMobileModel",
                .product(name: "CmuxAuthRuntime", package: "CmuxAuthRuntime"),
                .product(name: "CMUXAuthCore", package: "CMUXAuthCore"),
                .product(name: "StackAuth", package: "stack-auth-swift-sdk-prerelease"),
            ]
        ),
        .target(
            name: "CmuxMobileOnboarding",
            dependencies: ["CmuxMobileDesign", "CmuxMobileModel", "CmuxMobileAuth"],
            resources: [.process("Resources")]
        ),
        .target(name: "CmuxMobileSettings", dependencies: ["CmuxMobileDesign", "CmuxMobileModel", "CmuxMobileAuth", "CmuxMobileOnboarding", "CmuxMobileRealtime", "CmuxMobileScreenSharing"], resources: [.process("Resources")]),
        // Streamed browser tabs: a Mac browser page as H.264 video over the link's
        // `browser` service (VideoToolbox decode, rb input, rb.page chrome).
        .target(name: "CmuxMobileBrowserStream", dependencies: ["CmuxMobileDesign", "CmuxMobileTransport"]),
        // Workspaces list and the per-workspace TabsKit navigation (last tab first).
        .target(name: "CmuxMobileWorkspaces", dependencies: [
            "CmuxMobileDesign", "CmuxMobileModel", "CmuxMobileAgentChat", "CmuxMobileBrowserStream",
            .product(name: "CmuxTabsKit", package: "CmuxTabsKit"),
            .product(name: "CmuxAgentBrands", package: "CmuxAgentBrands"),
        ]),
        // Home: the Messages-style conversation list and the Chief chat over CmuxConversation.
        .target(name: "CmuxMobileChief", dependencies: [
            "CmuxMobileDesign", "CmuxMobileModel", "CmuxMobileTransport", "CmuxMobileAgentChat", "CmuxMobileArtifacts", "CmuxMobileNotifications",
            .product(name: "CmuxAgentBrands", package: "CmuxAgentBrands"),
            .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
            .product(name: "CmuxConversationCore", package: "CmuxConversation"),
            .product(name: "CmuxConversationUI", package: "CmuxConversation", condition: .when(platforms: [.iOS])),
            .product(name: "CmuxMobileSupport", package: "CmuxMobileSupport", condition: .when(platforms: [.iOS])),
        ], resources: [.process("Resources")]),
        // Live data: device registry, presence, the Mac link state machine, the
        // daemon tree, acpmux chats, Feed events and Chief over the link.
        .target(name: "CmuxMobileLive", dependencies: [
            "CmuxMobileDesign", "CmuxMobileModel", "CmuxMobileTransport", "CmuxMobileAgentChat", "CmuxMobileArtifacts", "CmuxMobileFeed", "CmuxMobileChief", "CmuxMobileTerminal",
            "CmuxMobileBrowserStream", "CmuxMobileNotifications",
            .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
            .product(name: "CmuxAgentBrands", package: "CmuxAgentBrands"),
            .product(name: "CmuxConversationCore", package: "CmuxConversation"),
        ]),
        .target(
            name: "CmuxMobileTerminal",
            // libghostty ships for iOS only here; macOS `swift test` builds the
            // portable parts (session, detector, extractor, input) without it.
            dependencies: [
                "CmuxMobileDesign", "CmuxMobileArtifacts", "CmuxMobileTransport",
                .product(name: "CmuxGhosttyKit", package: "CmuxGhosttyKit", condition: .when(platforms: [.iOS])),
                .product(name: "CmuxMobileSupport", package: "CmuxMobileSupport", condition: .when(platforms: [.iOS])),
            ]
        ),
        // Live Chief calls, portable part: the Realtime API's events and session config, the call's
        // state machine and tools, the OpenAI key in the Keychain (Foundation and Security only).
        .target(name: "CmuxMobileRealtime"),
        // Screen Sharing (Settings → Screen Sharing): the account's Macs from the device hub,
        // the approval flow and the full-screen viewer (CmuxScreenKitUI) of a Mac's screen.
        .target(name: "CmuxMobileScreenSharing", dependencies: [
            "CmuxMobileDesign",
            .product(name: "CmuxDeviceHub", package: "CmuxDeviceHub"),
            .product(name: "CmuxScreenKit", package: "CmuxScreenKit", condition: .when(platforms: [.iOS])),
            .product(name: "CmuxScreenKitUI", package: "CmuxScreenKit", condition: .when(platforms: [.iOS])),
        ]),
        // Chief calls: the Action Button voice note (recorder, on-device transcriber, delivery to Chief)
        // and the live call (WebRTC link to the Realtime API, call screen, Chief's tools).
        .target(
            name: "CmuxMobileVoice",
            dependencies: [
                "CmuxMobileChief", "CmuxMobileModel", "CmuxMobileDesign", "CmuxMobileRealtime",
                // libwebrtc for live Chief calls: CmuxVNCWebRTC's, the one build the app links.
                .product(name: "WebRTC", package: "CmuxVNCWebRTC", condition: .when(platforms: [.iOS])),
                .product(name: "CmuxChiefVoiceCore", package: "CmuxChiefVoiceCore"),
                .product(name: "CmuxConversationCore", package: "CmuxConversation"),
            ],
            resources: [.process("Resources")]
        ),
        .target(
            name: "CmuxMobileShell",
            dependencies: [
                "CmuxMobileDesign", "CmuxMobileModel", "CmuxMobileAuth", "CmuxMobileOnboarding", "CmuxMobileSettings",
                "CmuxMobileAgentChat", "CmuxMobileFeed", "CmuxMobileTransport", "CmuxMobileWorkspaces", "CmuxMobileChief", "CmuxMobileLive", "CmuxMobileTerminal",
                "CmuxMobileBrowserStream", "CmuxMobileNotifications", "CmuxMobileVoice", "CmuxMobileRealtime", "CmuxMobileScreenSharing",
                .product(name: "CmuxDeviceHub", package: "CmuxDeviceHub"),
                .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
                .product(name: "CmuxMobileSupport", package: "CmuxMobileSupport", condition: .when(platforms: [.iOS])),
            ]
        ),
        .testTarget(name: "CmuxMobileRealtimeTests", dependencies: ["CmuxMobileRealtime"]),
        .testTarget(name: "CmuxMobileScreenSharingTests", dependencies: [
            "CmuxMobileScreenSharing",
            .product(name: "CmuxDeviceHub", package: "CmuxDeviceHub"),
            .product(name: "CmuxScreenKit", package: "CmuxScreenKit", condition: .when(platforms: [.iOS])),
        ]),
        .testTarget(name: "CmuxMobileModelTests", dependencies: ["CmuxMobileModel"]),
        .testTarget(name: "CmuxMobileNotificationsTests", dependencies: ["CmuxMobileNotifications"]),
        .testTarget(name: "CmuxMobileTransportTests", dependencies: ["CmuxMobileTransport"]),
        .testTarget(name: "CmuxMobileAgentChatTests", dependencies: ["CmuxMobileAgentChat", "CmuxMobileDiff", "CmuxMobileMarkdown", "CmuxMobileArtifacts", "CmuxMobileDesign", "CmuxMobileTransport"]),
        .testTarget(name: "CmuxMobileTerminalTests", dependencies: ["CmuxMobileTerminal"]),
        .testTarget(name: "CmuxMobileBrowserStreamTests", dependencies: ["CmuxMobileBrowserStream", "CmuxMobileTransport"]),
        .testTarget(name: "CmuxMobileWorkspacesTests", dependencies: [
            "CmuxMobileWorkspaces", "CmuxMobileModel", "CmuxMobileAgentChat", "CmuxMobileDesign", "CmuxMobileBrowserStream", "CmuxMobileTransport",
        ]),
        .testTarget(name: "CmuxMobileLiveTests", dependencies: [
            "CmuxMobileLive", "CmuxMobileNotifications", "CmuxMobileTransport", "CmuxMobileModel", "CmuxMobileAgentChat", "CmuxMobileFeed", "CmuxMobileTerminal", "CmuxMobileDesign",
            .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
            .product(name: "CmuxConversationCore", package: "CmuxConversation"),
        ]),
        .testTarget(name: "CmuxMobileShellTests", dependencies: ["CmuxMobileShell", "CmuxMobileNotifications", "CmuxMobileModel", "CmuxMobileLive", "CmuxMobileDesign"]),
        .testTarget(name: "CmuxMobileOnboardingTests", dependencies: ["CmuxMobileOnboarding"]),
        .testTarget(name: "CmuxMobileChiefTests", dependencies: [
            "CmuxMobileChief", "CmuxMobileTransport", "CmuxMobileModel", "CmuxMobileAgentChat",
            .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
            .product(name: "CmuxConversationCore", package: "CmuxConversation"),
            .product(name: "CmuxConversationUI", package: "CmuxConversation", condition: .when(platforms: [.iOS])),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
