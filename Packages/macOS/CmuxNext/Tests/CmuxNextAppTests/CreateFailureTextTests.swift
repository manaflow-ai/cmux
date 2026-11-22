import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDaemonService
import Testing

/// P0 2026-10-30, lead decision: a refused create's text reaches the person (the refusal HUD), so it is localized at the
/// app boundary; `PendingPaneNotCreated`'s English description stays for the log.
@MainActor struct CreateFailureTextTests {
    @Test func aPendingPaneThatWasNeverMadeReadsInTheAppsLanguage() {
        let failure = ActionWorkFailure.create("split", PendingPaneNotCreated())
        #expect(failure.message.contains(MiscHandlerStrings.pendingPaneNotCreated))
        #expect(!failure.message.contains(PendingPaneNotCreated().description))
    }

    /// Review #5 B2: a pane verb on a pane still opening is one typed refusal in the app's language, not a raw daemon error.
    @Test func aPaneStillOpeningIsATypedLocalizedRefusal() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current(["CMUX_NEXT_NO_ACTIVATE": "1"]))
        let failure = services.daemon.workFailure("zoom-pane", PaneNotReady(command: "zoom-pane", reference: "pane=4611686018427387905"))
        #expect(failure.refusal == .unavailable)
        #expect(failure.message == MiscHandlerStrings.paneNotReady)
        #expect(!failure.message.contains("4611686018427387905"), "the stand-in id reached the person's text")
    }
}
