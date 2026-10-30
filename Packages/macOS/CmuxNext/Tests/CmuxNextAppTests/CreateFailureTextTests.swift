import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// P0 2026-10-30, lead decision: a refused create's text reaches the person (the refusal HUD), so it is localized at the
/// app boundary; `PendingPaneNotCreated`'s English description stays for the log.
struct CreateFailureTextTests {
    @Test func aPendingPaneThatWasNeverMadeReadsInTheAppsLanguage() {
        let failure = ActionWorkFailure.create("split", PendingPaneNotCreated())
        #expect(failure.message.contains(MiscHandlerStrings.pendingPaneNotCreated))
        #expect(!failure.message.contains(PendingPaneNotCreated().description))
    }
}
