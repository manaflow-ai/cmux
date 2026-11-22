import CmuxNextActions
import CmuxNextDaemon
import CmuxNextDaemonService
import Testing

/// A daemon intent's failure as the sidebar reports it (`ActionRegistry.reportFailure`, the "Move" of a drag): a missed
/// deadline shows nothing, a daemon refusal or a lost connection shows only that the move did not apply, and no notice
/// names the command, the op or a deadline (Leo, 2026-11-04, on "Move did not apply: set-personal-workspace: timed out:
/// workspace.place (no reply within 2.0 seconds)": "did you encounter this? i dont like chatty unactionable toasts").
@MainActor
@Suite struct DaemonFailureNoticeTests {
    private static func notices(_ error: DaemonError) -> [String] {
        let registry = ActionRegistry(catalog: [ActionDescriptor(id: "sidebar.move", title: "Move", category: .other)])
        var shown: [String] = []
        registry.remoteFailureObserver = { _, notice in shown.append(notice) }
        registry.reportFailure(of: "sidebar.move", title: "Move", ActionWorkFailure("set-personal-workspace", error))
        return shown
    }

    @Test func aTimedOutPlacementShowsNoNotice() {
        #expect(Self.notices(.timedOut("workspace.place (no reply within 2.0 seconds)")).isEmpty)
    }

    @Test func aLostConnectionSaysOnlyThatTheMoveDidNotApply() {
        #expect(Self.notices(.notConnected) == ["Move did not apply."])
        #expect(Self.notices(.connectionClosed(reason: "eof")) == ["Move did not apply."])
        #expect(Self.notices(.daemonShutdown) == ["Move did not apply."])
    }

    @Test func aDaemonRefusalShowsOnlyThatTheMoveDidNotApply() {
        let refused = DaemonError.command(cmd: "workspace.place", message: "no workspace matches ws_1", code: "not_found")
        #expect(Self.notices(refused) == ["Move did not apply."])
    }

    @Test func noDaemonErrorLeaksIntoANotice() {
        let errors: [DaemonError] = [
            .timedOut("workspace.place (no reply within 2.0 seconds)"), .terminalStartTimedOut("new-tab"),
            .command(cmd: "workspace_group.update", message: "busy", code: "busy"), .malformedResponse("{"),
            .notConnected, .connectionClosed(reason: "eof"), .daemonShutdown,
        ]
        for error in errors {
            for notice in Self.notices(error) {
                #expect(!notice.contains("set-personal-workspace") && !notice.contains("workspace") && !notice.contains("timed out")
                        && !notice.contains("no reply"), "\(error) showed \(notice)")
            }
        }
    }
}
