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
        .package(path: "../../Packages/iOS/CmuxConversation"),
        // The agents' brand marks (Claude, Codex), shared with the Mac app.
        .package(path: "../../Packages/Shared/CmuxAgentBrands"),
        // The Action Button call flow (plans/cmux-next/ios-action-button-DESIGN.md).
        .package(path: "../../Packages/Shared/CmuxChiefVoiceCore"),
    ],
    targets: [
        .target(name: "CmuxMobileDesign"),
        // Push payloads, notification buttons, the App Group outbox and chat
        // snapshots: Foundation and UserNotifications only, so the notification
        // extensions link it without the app's modules (verify/rich-push.md).
        .target(name: "CmuxMobileNotifications"),
        .target(name: "CmuxMobileModel"),
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
        .target(name: "CmuxMobileMarkdown", dependencies: ["CmuxMobileDesign"], resources: [.copy("Resources/web")]),
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
        .target(name: "CmuxMobileSettings", dependencies: ["CmuxMobileDesign", "CmuxMobileModel", "CmuxMobileAuth", "CmuxMobileOnboarding", "CmuxMobileRealtime"]),
        // Streamed browser tabs: a Mac browser page as H.264 video over the link's
        // `browser` service (VideoToolbox decode, rb input, rb.page chrome).
        .target(name: "CmuxMobileBrowserStream", dependencies: ["CmuxMobileDesign", "CmuxMobileTransport"]),
        // Workspaces list and the per-workspace TabsKit navigation (last tab first).
        .target(name: "CmuxMobileWorkspaces", dependencies: [
            "CmuxMobileDesign", "CmuxMobileModel", "CmuxMobileAgentChat", "CmuxMobileBrowserStream",
            .product(name: "CmuxTabsKit", package: "CmuxTabsKit"),
        ]),
        // Home: the Messages-style conversation list and the Chief chat over CmuxConversation.
        .target(name: "CmuxMobileChief", dependencies: [
            "CmuxMobileDesign", "CmuxMobileModel", "CmuxMobileTransport", "CmuxMobileAgentChat", "CmuxMobileArtifacts",
            .product(name: "CmuxAgentBrands", package: "CmuxAgentBrands"),
            .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
            .product(name: "CmuxConversationCore", package: "CmuxConversation"),
            .product(name: "CmuxConversationUI", package: "CmuxConversation", condition: .when(platforms: [.iOS])),
        ]),
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
            dependencies: ["CmuxMobileDesign", "CmuxMobileArtifacts", "CmuxMobileTransport", .product(name: "CmuxGhosttyKit", package: "CmuxGhosttyKit", condition: .when(platforms: [.iOS]))]
        ),
        // Live Chief calls, portable part: the Realtime API's events and session config, the call's
        // state machine and tools, the OpenAI key in the Keychain (Foundation and Security only).
        .target(name: "CmuxMobileRealtime"),
        // libwebrtc for live Chief calls (the build CmuxVNCWebRTC and the CmuxLink lanes pin).
        .binaryTarget(
            name: "WebRTC",
            url: "https://github.com/stasel/WebRTC/releases/download/154.0.0/WebRTC-M154.xcframework.zip",
            checksum: "a2bcdda93578c82452ceb6e49d54a2746e1bcb4caf7c2fa601ffac8028b58c16"
        ),
        // Chief calls: the Action Button voice note (recorder, on-device transcriber, delivery to Chief)
        // and the live call (WebRTC link to the Realtime API, call screen, Chief's tools).
        .target(
            name: "CmuxMobileVoice",
            dependencies: [
                "CmuxMobileChief", "CmuxMobileModel", "CmuxMobileDesign", "CmuxMobileRealtime",
                .target(name: "WebRTC", condition: .when(platforms: [.iOS])),
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
                "CmuxMobileBrowserStream", "CmuxMobileNotifications", "CmuxMobileVoice", "CmuxMobileRealtime",
                .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
            ]
        ),
        .testTarget(name: "CmuxMobileRealtimeTests", dependencies: ["CmuxMobileRealtime"]),
        .testTarget(name: "CmuxMobileModelTests", dependencies: ["CmuxMobileModel"]),
        .testTarget(name: "CmuxMobileNotificationsTests", dependencies: ["CmuxMobileNotifications"]),
        .testTarget(name: "CmuxMobileTransportTests", dependencies: ["CmuxMobileTransport"]),
        .testTarget(name: "CmuxMobileAgentChatTests", dependencies: ["CmuxMobileAgentChat", "CmuxMobileDiff", "CmuxMobileMarkdown", "CmuxMobileArtifacts", "CmuxMobileDesign"]),
        .testTarget(name: "CmuxMobileTerminalTests", dependencies: ["CmuxMobileTerminal"]),
        .testTarget(name: "CmuxMobileBrowserStreamTests", dependencies: ["CmuxMobileBrowserStream", "CmuxMobileTransport"]),
        .testTarget(name: "CmuxMobileWorkspacesTests", dependencies: ["CmuxMobileWorkspaces", "CmuxMobileModel", "CmuxMobileAgentChat", "CmuxMobileDesign"]),
        .testTarget(name: "CmuxMobileLiveTests", dependencies: [
            "CmuxMobileLive", "CmuxMobileNotifications", "CmuxMobileTransport", "CmuxMobileModel", "CmuxMobileAgentChat", "CmuxMobileFeed", "CmuxMobileTerminal", "CmuxMobileDesign",
            .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
        ]),
        .testTarget(name: "CmuxMobileShellTests", dependencies: ["CmuxMobileShell", "CmuxMobileNotifications", "CmuxMobileModel", "CmuxMobileLive", "CmuxMobileDesign"]),
        .testTarget(name: "CmuxMobileOnboardingTests", dependencies: ["CmuxMobileOnboarding"]),
        .testTarget(name: "CmuxMobileChiefTests", dependencies: [
            "CmuxMobileChief", "CmuxMobileTransport", "CmuxMobileModel", "CmuxMobileAgentChat",
            .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
            .product(name: "CmuxConversationCore", package: "CmuxConversation"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)
