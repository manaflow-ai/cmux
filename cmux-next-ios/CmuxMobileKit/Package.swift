// swift-tools-version: 6.2

import Foundation
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
        .package(path: "../../Packages/Shared/CmuxEgress"),
        .package(path: "../../Packages/Shared/CmuxGhosttyKit"),
        .package(path: "../../Packages/Shared/CmuxAgentQuestion"),
        // A message's preview words (MessagePreview), shared with the Mac's Home.
        .package(path: "../../Packages/Shared/CmuxHomeCore"),
        // Shared Stack Auth runtime (used as-is; do not modify from here).
        .package(path: "../../Packages/Shared/CmuxAuthRuntime"),
        // Connectivity observability: verbose for the cmux team, sampled for everyone.
        .package(path: "../../Packages/Shared/CmuxConnectivityTelemetry"),
        .package(path: "../../Packages/Shared/CMUXAuthCore"),
        .package(path: "../../vendor/stack-auth-swift-sdk-prerelease"),
        // Safari-style tabs (workspaces) and the Messages-style conversation (Chief).
        .package(path: "../../Packages/iOS/CmuxTabsKit"),
        // Shared composer and keyboard support from the classic app, used as-is.
        .package(path: "../../Packages/iOS/CmuxMobileSupport"),
        .package(path: "../../Packages/iOS/CmuxConversation"),
        // App Store plans (StoreKit 2, server-verified by cmux.com), shared with the classic app.
        .package(path: "../../Packages/iOS/CmuxMobileBilling"),
        // The agents' brand marks (Claude, Codex), shared with the Mac app.
        .package(path: "../../Packages/Shared/CmuxAgentBrands"),
        // The Action Button call flow (plans/cmux-next/ios-action-button-DESIGN.md).
        .package(path: "../../Packages/Shared/CmuxChiefVoiceCore"),
        // Screen Sharing: this iPhone as a device of the device hub, and the Mac screen viewer
        // (CmuxScreenKit, over CmuxVNCWebRTC, which also provides the app's one WebRTC.framework).
        .package(path: "../../Packages/Shared/CmuxDeviceHub"),
        .package(path: "../../Packages/Shared/CmuxScreenKit"),
        .package(path: "../../Packages/Shared/CmuxVNCWebRTC"),
        // The one spinner, on the period every cmux spinner turns at (shared with the web pages and the Mac).
        .package(path: "../../Packages/Shared/CmuxSpinner"),
        // The one Chief list rule, shared with the Mac's Home.
        .package(path: "../../Packages/Shared/CmuxChiefList"),
        // The Mac chrome's colors from a terminal theme (ThemeTokens.derive): the phone derives the
        // same palette from the theme its Mac sends, or from its cached copy offline (ask-87d30da8e5).
        .package(path: "../../Packages/Shared/CmuxTheme"),
    ],
    targets: [
        // CmuxMobileDesign's pure rules (no UI framework), which build and test on Linux; CmuxMobileDesign re-exports it.
        .target(name: "CmuxMobileDesignCore"),
        .target(name: "CmuxMobileDesign", dependencies: ["CmuxMobileDesignCore", .product(name: "CmuxSpinner", package: "CmuxSpinner"), .product(name: "CmuxTheme", package: "CmuxTheme")], resources: [.process("Resources")]),
        // Push payloads, notification buttons, the App Group outbox and chat
        // snapshots: Foundation and UserNotifications only, so the notification
        // extensions link it without the app's modules (verify/rich-push.md).
        .target(name: "CmuxMobileNotifications"),
        // CMUXAuthCore: CMUXBuildSpace, the dev build's X-Cmux-Build-Space header.
        .target(name: "CmuxMobileModel", dependencies: ["CmuxMobileDesignCore", .product(name: "CmuxEgress", package: "CmuxEgress"), .product(name: "CMUXAuthCore", package: "CMUXAuthCore")], resources: [.process("Resources")]),
        .binaryTarget(name: "CmuxMobileLinkFFIFFI", path: "Frameworks/CmuxMobileLinkFFI.xcframework"),
        .target(
            name: "CmuxMobileLinkFFI",
            dependencies: [.target(name: "CmuxMobileLinkFFIFFI", condition: .when(platforms: [.iOS]))],
            path: "Sources/CmuxMobileLinkFFI",
            // uniffi's generated Swift is not Swift 6 concurrency-clean.
            swiftSettings: [.swiftLanguageMode(.v5)],
            // CFNetwork: the system's proxy settings and PAC (cmux-mobile-link egress/apple.rs).
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("SystemConfiguration"), .linkedFramework("CFNetwork")]
        ),
        .target(name: "CmuxMobileTransport", dependencies: [.target(name: "CmuxMobileLinkFFI", condition: .when(platforms: [.iOS]))]),
        // Markdown: native block renderer for transcripts, WKWebView renderer (pooled) for the Feed and math.
        .target(name: "CmuxMobileMarkdown", dependencies: ["CmuxMobileDesign", "CmuxMobileModel"], resources: [.copy("Resources/web")]),
        // Diff model (line + word diff, unified parser) and the GitHub-mobile-style viewer.
        .target(name: "CmuxMobileDiff", dependencies: ["CmuxMobileDesign"]),
        // Session artifacts: the reference model and extractor, sources (mock, inline, the Mac's `file`
        // link service), the browser and previews. Shared by the terminal and agent sessions.
        .target(name: "CmuxMobileArtifacts", dependencies: [.product(name: "CmuxSpinner", package: "CmuxSpinner"), "CmuxMobileDesign", "CmuxMobileTransport", "CmuxMobileRealtime"]),
        // ACP agent session model, AgentSessionSource (mock now, acpmux over the link later), chat screen.
        .target(name: "CmuxMobileAgentChat", dependencies: [
            .product(name: "CmuxSpinner", package: "CmuxSpinner"),
            "CmuxMobileDesign", "CmuxMobileModel", "CmuxMobileMarkdown", "CmuxMobileDiff", "CmuxMobileArtifacts", "CmuxMobileTransport",
            "CmuxMobileRealtime",
            .product(name: "CmuxAgentBrands", package: "CmuxAgentBrands"),
            .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
            .product(name: "CmuxMobileSupport", package: "CmuxMobileSupport", condition: .when(platforms: [.iOS])),
            // Kept row heights, keyed by row and content (ChatRowHeightMemory): Rust's RowLayoutMemory.
            .target(name: "CmuxMobileLinkFFI", condition: .when(platforms: [.iOS])),
        ], resources: [.process("Resources")]),
        .target(name: "CmuxMobileFeed", dependencies: [
            .product(name: "CmuxSpinner", package: "CmuxSpinner"),
            "CmuxMobileDesign", "CmuxMobileModel", "CmuxMobileMarkdown", "CmuxMobileAgentChat",
            .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
        ]),
        .target(
            name: "CmuxMobileAuth",
            dependencies: [ // sorted: scripts/cmux-next/check-package-dependency-lists.py
                "CmuxMobileModel",
                .product(name: "CMUXAuthCore", package: "CMUXAuthCore"),
                .product(name: "CmuxAuthRuntime", package: "CmuxAuthRuntime"),
                .product(name: "CmuxEgress", package: "CmuxEgress"),
                .product(name: "CmuxMobileBilling", package: "CmuxMobileBilling"),
                .product(name: "StackAuth", package: "stack-auth-swift-sdk-prerelease"),
            ]
        ),
        .target(
            name: "CmuxMobileOnboarding",
            dependencies: [ // sorted: scripts/cmux-next/check-package-dependency-lists.py
                "CmuxMobileAuth",
                "CmuxMobileDesign",
                "CmuxMobileModel",
                .product(name: "CmuxSpinner", package: "CmuxSpinner"),
            ],
            resources: [.process("Resources")]
        ),
        .target(name: "CmuxMobileSettings", dependencies: [.product(name: "CmuxSpinner", package: "CmuxSpinner"), "CmuxMobileDesign", "CmuxMobileModel", "CmuxMobileAuth", "CmuxMobileOnboarding", "CmuxMobileRealtime", "CmuxMobileScreenSharing", .product(name: "CmuxMobileBillingUI", package: "CmuxMobileBilling", condition: .when(platforms: [.iOS])), .product(name: "CmuxConnectivityTelemetry", package: "CmuxConnectivityTelemetry")], resources: [.process("Resources")]),
        // Streamed browser tabs: a Mac browser page as H.264 video over the link's
        // `browser` service (VideoToolbox decode, rb input, rb.page chrome).
        .target(name: "CmuxMobileBrowserStream", dependencies: ["CmuxMobileDesign", "CmuxMobileModel", "CmuxMobileTransport", "CmuxMobileRealtime"]),
        // Workspaces list and the per-workspace TabsKit navigation (last tab first).
        .target(name: "CmuxMobileWorkspaces", dependencies: [
            .product(name: "CmuxSpinner", package: "CmuxSpinner"),
            "CmuxMobileDesign", "CmuxMobileModel", "CmuxMobileAgentChat", "CmuxMobileBrowserStream",
            // Close Tab as one traced user action (PhoneTrace, CMUX_TRACE_FILE).
            "CmuxMobileTransport",
            // The + menu's Screen Sharing: the account's Macs and the viewer.
            "CmuxMobileScreenSharing",
            .product(name: "CmuxTabsKit", package: "CmuxTabsKit"),
            .product(name: "CmuxAgentBrands", package: "CmuxAgentBrands"),
            // Toggle Terminal and Chat: which faces a tab offers and what a tap does are Rust's.
            .target(name: "CmuxMobileLinkFFI", condition: .when(platforms: [.iOS])),
        ]),
        // Home: the Messages-style conversation list and the Chief chat over CmuxConversation.
        // CmuxMobileBrowserStream: the info page's Computer card streams a Cloud machine's screen.
        .target(name: "CmuxMobileChief", dependencies: [
            .product(name: "CmuxEgress", package: "CmuxEgress"),
            .product(name: "CmuxSpinner", package: "CmuxSpinner"),
            .product(name: "CmuxChiefList", package: "CmuxChiefList"),
            "CmuxMobileDesign", "CmuxMobileModel", "CmuxMobileTransport", "CmuxMobileAgentChat", "CmuxMobileMarkdown", "CmuxMobileArtifacts", "CmuxMobileNotifications",
            "CmuxMobileBrowserStream",
            .product(name: "CmuxAgentBrands", package: "CmuxAgentBrands"),
            .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
            .product(name: "CmuxConversationCore", package: "CmuxConversation"),
            .product(name: "CmuxConversationUI", package: "CmuxConversation", condition: .when(platforms: [.iOS])),
            .product(name: "CmuxMobileSupport", package: "CmuxMobileSupport", condition: .when(platforms: [.iOS])),
            .product(name: "CMUXAuthCore", package: "CMUXAuthCore"),
            .product(name: "CmuxHomeCore", package: "CmuxHomeCore"),
        ], resources: [.process("Resources")]),
        // Live data: device registry, presence, the Mac link state machine, the
        // daemon tree, acpmux chats, Feed events and Chief over the link.
        .target(name: "CmuxMobileLive", dependencies: [
            .product(name: "CmuxEgress", package: "CmuxEgress"),
            "CmuxMobileDesign", "CmuxMobileModel", "CmuxMobileTransport", "CmuxMobileAgentChat", "CmuxMobileArtifacts", "CmuxMobileFeed", "CmuxMobileChief", "CmuxMobileTerminal",
            "CmuxMobileBrowserStream", "CmuxMobileNotifications",
            // The classic app's leftovers after an update (ClassicLeftovers): the plan is Rust's.
            .target(name: "CmuxMobileLinkFFI", condition: .when(platforms: [.iOS])),
            .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
            .product(name: "CmuxAgentBrands", package: "CmuxAgentBrands"),
            .product(name: "CmuxConnectivityTelemetry", package: "CmuxConnectivityTelemetry"),
            .product(name: "CmuxConversationCore", package: "CmuxConversation"),
            .product(name: "CMUXAuthCore", package: "CMUXAuthCore"),
        ]),
        .target(
            name: "CmuxMobileTerminal",
            // libghostty ships for iOS only here; macOS `swift test` builds the
            // portable parts (session, detector, extractor, input) without it.
            dependencies: [ // sorted: scripts/cmux-next/check-package-dependency-lists.py
                "CmuxMobileArtifacts",
                "CmuxMobileDesign",
                "CmuxMobileRealtime",
                "CmuxMobileTransport",
                .product(name: "CmuxGhosttyKit", package: "CmuxGhosttyKit", condition: .when(platforms: [.iOS])),
                .product(name: "CmuxMobileSupport", package: "CmuxMobileSupport", condition: .when(platforms: [.iOS])),
                .product(name: "CmuxSpinner", package: "CmuxSpinner"),
                // Predictive local echo: the shared Rust engine (cmux-terminal-prediction).
                .target(name: "CmuxMobileLinkFFI", condition: .when(platforms: [.iOS])),
            ]
        ),
        // Live Chief calls and agent voice mode, portable part: the Realtime API's events and session
        // configs, the call's and voice mode's state machines, the speech filter and tools, the OpenAI key in the Keychain (Foundation and Security only).
        .target(name: "CmuxMobileRealtime", dependencies: [.product(name: "CmuxEgress", package: "CmuxEgress")]),
        // Screen Sharing (Settings → Screen Sharing): the account's Macs from the device hub,
        // the approval flow and the full-screen viewer (CmuxScreenKitUI) of a Mac's screen.
        .target(name: "CmuxMobileScreenSharing", dependencies: [
            .product(name: "CmuxSpinner", package: "CmuxSpinner"),
            "CmuxMobileDesign", "CmuxMobileModel",
            // Mac Screen over Link: the Mac's display as rd/1 on the paired Mac's link (`d~0`).
            "CmuxMobileBrowserStream",
            .product(name: "CmuxDeviceHub", package: "CmuxDeviceHub"),
            .product(name: "CmuxScreenKit", package: "CmuxScreenKit", condition: .when(platforms: [.iOS])),
            .product(name: "CmuxScreenKitUI", package: "CmuxScreenKit", condition: .when(platforms: [.iOS])),
            // A `cmux://mac-screen` link's cmux.rd/1 session: Rust's MacScreenRd on the streamed-surface model.
            "CmuxMobileBrowserStream", "CmuxMobileTransport",
            // Follow mode's camera (FollowCamera).
            .target(name: "CmuxMobileLinkFFI", condition: .when(platforms: [.iOS])),
        ]),
        // Chief calls: the Action Button voice note (recorder, on-device transcriber, delivery to Chief)
        // and the live call (WebRTC link to the Realtime API, call screen, Chief's tools).
        .target(
            name: "CmuxMobileVoice",
            dependencies: [ // sorted: scripts/cmux-next/check-package-dependency-lists.py
                "CmuxMobileChief",
                "CmuxMobileDesign",
                "CmuxMobileModel",
                "CmuxMobileRealtime",
                .product(name: "CmuxChiefVoiceCore", package: "CmuxChiefVoiceCore"),
                .product(name: "CmuxConversationCore", package: "CmuxConversation"),
                .product(name: "CmuxSpinner", package: "CmuxSpinner"),
                // The process's libwebrtc field trials (WebRTCFieldTrials), set before the call's factory.
                .product(name: "CmuxVNCWebRTC", package: "CmuxVNCWebRTC", condition: .when(platforms: [.iOS])),
                // libwebrtc for live Chief calls: CmuxVNCWebRTC's, the one build the app links.
                .product(name: "WebRTC", package: "CmuxVNCWebRTC", condition: .when(platforms: [.iOS])),
            ],
            resources: [.process("Resources")]
        ),
        .target(
            name: "CmuxMobileShell",
            dependencies: [ // sorted: scripts/cmux-next/check-package-dependency-lists.py
                "CmuxMobileAgentChat",
                "CmuxMobileAuth",
                "CmuxMobileBrowserStream",
                "CmuxMobileChief",
                "CmuxMobileDesign",
                "CmuxMobileFeed",
                "CmuxMobileLive",
                "CmuxMobileModel",
                "CmuxMobileNotifications",
                "CmuxMobileOnboarding",
                "CmuxMobileRealtime",
                "CmuxMobileScreenSharing",
                "CmuxMobileSettings",
                "CmuxMobileTerminal",
                "CmuxMobileTransport",
                "CmuxMobileVoice",
                "CmuxMobileWorkspaces",
                .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
                .product(name: "CmuxConnectivityTelemetry", package: "CmuxConnectivityTelemetry"),
                .product(name: "CmuxDeviceHub", package: "CmuxDeviceHub"),
                .product(name: "CmuxMobileBilling", package: "CmuxMobileBilling"),
                .product(name: "CmuxMobileBillingUI", package: "CmuxMobileBilling", condition: .when(platforms: [.iOS])),
                .product(name: "CmuxMobileSupport", package: "CmuxMobileSupport", condition: .when(platforms: [.iOS])),
                .product(name: "CmuxSpinner", package: "CmuxSpinner"),
                // The window's layout at its size (one pane or two), decided in Rust.
                .target(name: "CmuxMobileLinkFFI", condition: .when(platforms: [.iOS])),
            ]
        ),
        .testTarget(name: "CmuxMobileRealtimeTests", dependencies: ["CmuxMobileRealtime"]),
        .testTarget(name: "CmuxMobileDesignCoreTests", dependencies: ["CmuxMobileDesignCore"]),
        .testTarget(name: "CmuxMobileVoiceTests", dependencies: [
            "CmuxMobileVoice", "CmuxMobileChief", "CmuxMobileModel",
            .product(name: "CmuxConversationCore", package: "CmuxConversation"),
        ]),
        .testTarget(name: "CmuxMobileScreenSharingTests", dependencies: [
            "CmuxMobileScreenSharing",
            "CmuxMobileBrowserStream",
            .product(name: "CmuxDeviceHub", package: "CmuxDeviceHub"),
            .product(name: "CmuxScreenKit", package: "CmuxScreenKit", condition: .when(platforms: [.iOS])),
        ]),
        .testTarget(name: "CmuxMobileModelTests", dependencies: ["CmuxMobileModel", .product(name: "CMUXAuthCore", package: "CMUXAuthCore")]),
        .testTarget(name: "CmuxMobileAuthTests", dependencies: [
            "CmuxMobileAuth", "CmuxMobileModel", .product(name: "CmuxAuthRuntime", package: "CmuxAuthRuntime"),
        ]),
        .testTarget(name: "CmuxMobileNotificationsTests", dependencies: ["CmuxMobileNotifications"]),
        .testTarget(name: "CmuxMobileTransportTests", dependencies: ["CmuxMobileTransport"]),
        .testTarget(name: "CmuxMobileAgentChatTests", dependencies: ["CmuxMobileAgentChat", "CmuxMobileDiff", "CmuxMobileMarkdown", "CmuxMobileArtifacts", "CmuxMobileDesign", "CmuxMobileModel", "CmuxMobileTransport", "CmuxMobileRealtime"]),
        .testTarget(name: "CmuxMobileTerminalTests", dependencies: [
            "CmuxMobileTerminal", "CmuxMobileDesign",
            .product(name: "CmuxGhosttyKit", package: "CmuxGhosttyKit", condition: .when(platforms: [.iOS])),
            .target(name: "CmuxMobileLinkFFI", condition: .when(platforms: [.iOS])),
        ]),
        .testTarget(name: "CmuxMobileBrowserStreamTests", dependencies: ["CmuxMobileBrowserStream", "CmuxMobileTransport"]),
        .testTarget(name: "CmuxMobileWorkspacesTests", dependencies: [
            "CmuxMobileWorkspaces", "CmuxMobileModel", "CmuxMobileAgentChat", "CmuxMobileDesign", "CmuxMobileBrowserStream", "CmuxMobileTransport",
            .target(name: "CmuxMobileLinkFFI", condition: .when(platforms: [.iOS])),
        ]),
        .testTarget(name: "CmuxMobileLiveTests", dependencies: [
            "CmuxMobileLive", "CmuxMobileChief", "CmuxMobileNotifications", "CmuxMobileTransport", "CmuxMobileModel", "CmuxMobileAgentChat", "CmuxMobileFeed", "CmuxMobileTerminal", "CmuxMobileDesign", "CmuxMobileMarkdown",
            // TypingUnderLinkChurnTests: the workspace list and tabs source on screen while typing.
            "CmuxMobileWorkspaces",
            .target(name: "CmuxMobileLinkFFI", condition: .when(platforms: [.iOS])),
            .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
            .product(name: "CmuxConnectivityTelemetry", package: "CmuxConnectivityTelemetry"),
            .product(name: "CmuxConversationCore", package: "CmuxConversation"),
            .product(name: "CMUXAuthCore", package: "CMUXAuthCore"),
        ]),
        // The instant-list perf bench (small vs god fixtures, budgets and the 1.2x rule):
        // cmux-next-ios/design/instant-perf.md. CI runs it on its own, after the other tests.
        .testTarget(name: "CmuxMobileInstantPerfTests", dependencies: [
            "CmuxMobileChief", "CmuxMobileLive", "CmuxMobileAgentChat", "CmuxMobileTransport",
            "CmuxMobileModel", "CmuxMobileWorkspaces",
            // terminal_chat_swap: the Rust decision is inside the timed swap.
            .target(name: "CmuxMobileLinkFFI", condition: .when(platforms: [.iOS])),
        ]),
        .testTarget(name: "CmuxMobileShellTests", dependencies: ["CmuxMobileShell", "CmuxMobileSettings", "CmuxMobileNotifications", "CmuxMobileModel", "CmuxMobileLive", "CmuxMobileDesign", "CmuxMobileFeed", .product(name: "CmuxTheme", package: "CmuxTheme")]),
        .testTarget(name: "CmuxMobileOnboardingTests", dependencies: ["CmuxMobileOnboarding", "CmuxMobileDesign"]),
        .testTarget(name: "CmuxMobileChiefTests", dependencies: [
            "CmuxMobileChief", "CmuxMobileTransport", "CmuxMobileModel", "CmuxMobileAgentChat",
            .product(name: "CmuxChiefList", package: "CmuxChiefList"),
            .product(name: "CmuxAgentQuestion", package: "CmuxAgentQuestion"),
            .product(name: "CmuxConversationCore", package: "CmuxConversation"),
            .product(name: "CmuxConversationUI", package: "CmuxConversation", condition: .when(platforms: [.iOS])),
            .product(name: "CMUXAuthCore", package: "CMUXAuthCore"),
        ]),
    ],
    swiftLanguageModes: [.v6]
)

#if os(Linux)
// The Linux package job (swift-linux-packages.yml, group ios-kit) builds and tests the modules that need no
// UI framework, and no binary target (the gitignored CmuxMobileLinkFFI.xcframework, libghostty, WebRTC).
// Only that job sets CMUX_SWIFTPM_TARGET_LINUX: the fleet reads this manifest on Linux hosts to build for
// iOS and macOS, and keeps the whole package. cmux-next-ios-kit.yml skips these test targets on the Mac.
if ProcessInfo.processInfo.environment["CMUX_SWIFTPM_TARGET_LINUX"] == "1" {
    let linuxModules: Set<String> = [
        "CmuxMobileAuth", "CmuxMobileDesignCore", "CmuxMobileModel", "CmuxMobileNotifications", "CmuxMobileRealtime",
        "CmuxMobileTransport",
    ]
    let linuxTests = Set(linuxModules.map { $0 + "Tests" })
    package.products.removeAll { !linuxModules.contains($0.name) }
    package.targets.removeAll { !linuxModules.contains($0.name) && !linuxTests.contains($0.name) }
    for target in package.targets {
        target.dependencies.removeAll {
            if case .targetItem(name: "CmuxMobileLinkFFI", condition: _) = $0 { return true }
            return false
        }
    }
    // CmuxMobileAuth's portable TeamInviteFailure uses StackAuth's error protocol. The rest of
    // the target is the iOS-only coordinator and its Apple frameworks, so leave those package
    // products out of the Linux projection instead of making Linux resolve the app's auth graph.
    if let auth = package.targets.first(where: { $0.name == "CmuxMobileAuth" }) {
        auth.dependencies = [
            "CmuxMobileModel",
            .product(name: "StackAuth", package: "stack-auth-swift-sdk-prerelease"),
        ]
    }
    if let authTests = package.targets.first(where: { $0.name == "CmuxMobileAuthTests" }) {
        authTests.dependencies = ["CmuxMobileAuth", "CmuxMobileModel"]
    }
    package.dependencies = [
        .package(path: "../../Packages/Shared/CMUXAuthCore"),
        .package(path: "../../Packages/Shared/CmuxEgress"),
        .package(path: "../../vendor/stack-auth-swift-sdk-prerelease"),
        // CryptoKit's API for CmuxMobileNotifications (`import Crypto` where CryptoKit is absent).
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"),
    ]
    for target in package.targets where target.name == "CmuxMobileNotifications" || target.name == "CmuxMobileNotificationsTests" {
        target.dependencies.append(.product(name: "Crypto", package: "swift-crypto"))
    }
}
#endif
