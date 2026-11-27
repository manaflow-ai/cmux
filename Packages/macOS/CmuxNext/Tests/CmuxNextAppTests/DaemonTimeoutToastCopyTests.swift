import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDaemonService
import Testing

/// A change whose daemon command missed its deadline says so in words: the toast never shows the command
/// names (Leo, 2026-11-03, on "Move did not apply: set-personal-workspace: timed out: workspace.place (no reply
/// within 2.0 seconds)": "idk what happened here"). A caller (the control socket, the CLI) keeps the raw error.
@Suite struct DaemonTimeoutToastCopyTests {
    @Test func aTimedOutCommandShowsAReasonWithoutCommandNames() {
        let error = DaemonError.timedOut("workspace.place (no reply within 2.0 seconds)")
        let failure = ActionWorkFailure("set-personal-workspace", error)
        #expect(failure.mayHaveApplied)
        #expect(failure.message.contains("workspace.place"))
        let shown = failure.shownReason
        #expect(shown == RefusalStrings.daemonTimedOut)
        #expect(shown?.contains("workspace.place") == false)
        #expect(shown?.contains("set-personal-workspace") == false)
    }
}
