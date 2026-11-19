import AppKit
@testable import CmuxNextApp
import CmuxHomeCore
@testable import CmuxNextHome
import Testing
import CmuxNextTestSupport

/// The message box's file picker is made ahead of the click (`HomeAttachmentPanel`), but only in a
/// running app. A process that never ran the app's event loop (a test host, a ci-step mini with no
/// open-panel service) makes none: there `NSOpenPanel()` waits on the panel service's XPC endpoint
/// for ten seconds per listener and then ends the process (HomeImageDropTests died mid-test so).
///
/// The test checks that no panel is made, not how fast the warm-up runs: its checks fire on the main
/// actor, which a loaded runner running the whole parallel suite can hold for over a minute (every test
/// of a suite finished after 98 s on a 6-vCPU runner). The wait and the time limit are hang guards only.
@MainActor @Suite(.closesItsWindows, .serialized, .timeLimit(.minutes(10))) struct HomeAttachmentPanelWarmUpTests {
    @Test func aProcessThatNeverRanTheAppMakesNoPanelAhead() async throws {
        _ = NSApplication.shared
        #expect(!NSApp.isRunning, "the test host runs no app event loop")
        let services = AppServices(environment: AppEnvironment.current([:]))
        let view = HomeHostView(services: services, conversation: ConversationID("conv_panel_warm_up").rawValue)
        let panel = services.openPanel // the app's one, which Home's "+" takes
        #expect(view.transcript.canAttach, "the conversation takes attachments, so it would warm the panel")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        #expect(panel.isWarming, "the transcript in a window did not start the warm-up")
        // Until the warm-up has run its checks (the first at 2 s, idle retries 1 s apart, ten at most).
        // The loop ends on that condition; the deadline only stops a warm-up that never ends.
        let deadline = ContinuousClock.now + .seconds(300)
        let checks = panel.warmChecks
        while panel.warmChecks == checks || panel.isWarming, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(panel.warmChecks > checks && !panel.isWarming, "the warm-up never finished")
        #expect(!panel.isMade, "a panel was made ahead in a process that never ran the app")
    }
}
