import CmuxMobileAuth
import CmuxMobileModel
import CmuxMobileShell
import CmuxMobileVoice
#if DEBUG
import CmuxMobileLive
import CmuxMobileTerminal
#endif
import SwiftUI

@main
struct CmuxMobileApp: App {
    /// Push registration and notification taps (CmuxMobileShell).
    @UIApplicationDelegateAdaptor(CmuxMobileAppDelegate.self) private var appDelegate
    @State private var auth: CmuxMobileAuthModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Settings, account and outboxes saved under the pre-rename (cnx) names move first.
        LegacyStorage.migrate()
        #if !DEBUG
        // Release and Production have no Developer page: remove any developer
        // setting (mock data, a scripted demo, relay only) an earlier Debug
        // or Demo install left in this container, before anything reads them.
        DeveloperOptions.removeStoredValues()
        #endif
        let auth = CmuxMobileAuthModel.live(
            environment: ProcessInfo.processInfo.environment,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
        _auth = State(initialValue: auth)
        // A notification reply on a cold background launch signs in with it (no scene runs then).
        PushReplies.shared.auth = auth
        #if DEBUG
        // Screenshot rig: CMUX_MOBILE_FEED_LIVE_FIXTURE=1 fills the Feed from a fixed Mac.
        LiveFeedFixture.shared.startIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
            #if DEBUG
            if BrowserEventsDemoRoot.isRequested {
                BrowserEventsDemoRoot()
            } else if TerminalFloodBenchRoot.isRequested {
                TerminalFloodBenchRoot()
            } else if TerminalDemoRoot.isRequested || DeveloperOptions.launchDemo == "terminal" {
                TerminalDemoRoot()
            } else {
                RootView(auth: auth, store: .mock())
            }
            #else
            // Release and Production: no sample data; live data fills it once signed in.
            RootView(auth: auth, store: AppStore(teams: [], activeTeamID: "", workspaces: [], feed: []))
            #endif
            }
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
private let linkDialerProbe: any MacLinkDialer = FFIMacLinkDialer()
#endif
