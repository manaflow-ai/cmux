import CmuxConversationUI
import CmuxMobileAuth
import CmuxMobileDesign
import CmuxMobileLive
import CmuxMobileModel
import CmuxMobileShell
import CmuxMobileVoice
#if DEBUG
import CmuxMobileTerminal
import os
#endif
import SwiftUI

@main
struct CmuxMobileApp: App {
    /// Push registration and notification taps (CmuxMobileShell).
    @UIApplicationDelegateAdaptor(CmuxMobileAppDelegate.self) private var appDelegate
    @State private var auth: CmuxMobileAuthModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Launch to first interaction (LaunchMarks): dyld, static initializers and UIKit's start end here.
        LaunchMarks.shared.mark("app_init")
        #if DEBUG
        // `CMUX_MOBILE_LAUNCH_MARKS=1`: resume-after-switch marks for ResumeFromSwitchUITests.
        ResumeMarks.startIfRequested()
        #endif
        // An update from the classic app (the same bundle id) left its Keychain items and
        // settings here: they are deleted once, before anything reads either, so this app
        // starts signed out instead of half-reading a classic session.
        ClassicLeftovers.cleanUpIfDue()
        // Settings and account saved under the pre-rename (cnx) names move first.
        LegacyStorage.migrate()
        #if !CMUX_MOBILE_PRODUCTION
        // Messages' own + menu and tapback art (ConversationSystemArt). Every shipping
        // build (Production, TestFlight/cmux INTERNAL, AppStore) carries no
        // PrivateFrameworks path (App Review 2.5.1) and draws them.
        var chatKitPath = "/System/Library/PrivateFrameworks/ChatKit.framework"
        #if targetEnvironment(simulator)
        if let root = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] { chatKitPath = root + chatKitPath }
        #endif
        ConversationSystemArt.bundle = Bundle(path: chatKitPath)
        #endif
        #if !DEBUG
        // Release and Production have no Developer page: remove any developer
        // setting (mock data, a scripted demo, relay only) an earlier Debug
        // or Demo install left in this container, before anything reads them.
        DeveloperOptions.removeStoredValues()
        #else
        // A UI test's `-cmuxMobile.setupComplete NO` starts setup; setup's
        // own last page must still be able to finish it.
        DeveloperOptions.seedLaunchArguments()
        #endif
        // The build's dev tag (Info.plist CmuxMobileDevTag, Debug configuration only): its cloud
        // requests carry `X-Cmux-Build-Space: dev:<slug>` so dev builds never share cloud data. A
        // Debug build (not Demo, which pairs with nightly Macs) without a usable tag refuses every
        // cloud call rather than reach nightly's data.
        #if DEBUG && !CMUX_MOBILE_DEMO
        let devBuild = true
        #else
        let devBuild = false
        #endif
        let auth = CmuxMobileAuthModel.live(
            environment: ProcessInfo.processInfo.environment,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            devTag: Bundle.main.object(forInfoDictionaryKey: "CmuxMobileDevTag") as? String,
            devBuild: devBuild
        )
        _auth = State(initialValue: auth)
        // A notification reply on a cold background launch signs in with it (no scene runs then).
        PushReplies.shared.auth = auth
        #if DEBUG
        // The fleet simulator step's reducemotion=1 proof (scripts/ci/cmux-next-ios-sim.sh reads
        // this line back from the simulator's log): what UIKit tells this process at launch.
        Logger(subsystem: "dev.cmux.mobile", category: "accessibility")
            .notice("launch: isReduceMotionEnabled=\(UIAccessibility.isReduceMotionEnabled, privacy: .public)")
        // Screenshot rig: CMUX_MOBILE_FEED_LIVE_FIXTURE=1 fills the Feed from a fixed Mac.
        LiveFeedFixture.shared.startIfRequested()
        // Input responsiveness: main-thread hitches with stacks, keyboard windows, key and send latency.
        InputLatencyTrace.startIfRequested()
        if let trace = InputLatencyTrace.shared {
            ComposerDraftStore.mainThreadWrite = { trace.note("draft_file_write_main") }
        }
        // CMUX_MOBILE_FEED_TERMINAL_FIXTURE=1 (or =before): terminal agents' events from a fixed Mac.
        TerminalFeedFixture.shared.startIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
            #if DEBUG
            if BrowserEventsDemoRoot.isRequested {
                BrowserEventsDemoRoot()
            } else if RecoveryGalleryRoot.isRequested {
                RecoveryGalleryRoot()
            } else if ShellScreenSharingDemo.isRequested {
                ShellScreenSharingDemo()
            } else if ShellScreenSharingLink.isRequested {
                ShellScreenSharingLink()
            } else if TerminalFloodBenchRoot.isRequested {
                TerminalFloodBenchRoot()
            } else if TerminalHistoryWindowDemoRoot.isRequested {
                TerminalHistoryWindowDemoRoot()
            } else if TerminalResizeDemoRoot.isRequested {
                TerminalResizeDemoRoot()
            } else if AgentCLIHybridBenchRoot.isRequested {
                AgentCLIHybridBenchRoot()
            } else if TerminalDemoRoot.isRequested || DeveloperOptions.launchDemo == "terminal" {
                TerminalDemoRoot()
            } else if FoldSimulatorFrame<RootView>.isRequested {
                // A live fold and unfold inside one simulator window (UITests/FoldResizeUITests).
                FoldSimulatorFrame { RootView(auth: auth, store: .mock()) }
            } else {
                RootView(auth: auth, store: .mock())
            }
            #else
            // Release and Production: no sample data; live data fills it once signed in.
            RootView(auth: auth, store: AppStore(teams: [], activeTeamID: "", workspaces: [], feed: []))
            #endif
            }
            #if DEBUG
            // `CMUX_MOBILE_LAUNCH_MARKS=1`: the launch marks for LaunchTTIUITests.
            .overlay(alignment: .topLeading) { LaunchMarksProbe() }
            .overlay(alignment: .topTrailing) { InputLatencyProbe() }
            .overlay(alignment: .bottomLeading) { ResumeMarksProbe() }
            #endif
            .modifier(ChiefCallCover(
                controller: ChiefVoice.controller,
                scenePhase: scenePhase,
                accountID: auth.isSignedIn ? auth.user?.id : nil
            ))
            #if DEBUG
            // Rig: `-cmux-mobile-run-intent new-agent-chat` with CMUX_MOBILE_INTENT_MESSAGE runs the
            // App Shortcut's own perform() at launch, as the system would on a tap (a headless
            // simulator's Spotlight opens the app without running an app's intents).
            .task { await NewAgentChatIntent.runFromLaunchArguments() }
            // `-cmux-mobile-kbd-pin-trace` for every root, not only RootView's (TerminalDemoRoot's
            // terminal for the keyboard motion bench); it starts once.
            .task { KeyboardPinTrace.startIfRequested() }
            #endif
        }
    }
}

/// The Action Button / Shortcuts Chief call over every root (ChiefVoiceIntents.swift).
private struct ChiefCallCover: ViewModifier {
    let controller: ChiefVoiceController
    let scenePhase: ScenePhase
    let accountID: String?

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: Binding(
                get: { controller.presented != nil },
                set: { if !$0 { controller.dismiss() } }
            )) {
                ChiefCallScreen(controller: controller)
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                // Notes an earlier call saved go out when the app comes back.
                if phase == .active { Task { await controller.drainOutbox() } }
            }
            .task(id: accountID) {
                await controller.selectAccount(accountID)
            }
    }
}

#if DEBUG
import CmuxMobileTransport

/// Keeps the Rust link linked into debug builds so FFI breakage shows at build time.
private let linkDialerProbe: any MacLinkDialer = FFIMacLinkDialer(buildSpace: .success(nil))
#endif
