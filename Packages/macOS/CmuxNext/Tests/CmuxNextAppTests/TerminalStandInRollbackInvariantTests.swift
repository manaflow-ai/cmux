import CmuxNextDaemon
import CmuxNextDaemonService
import Testing

/// R3 for the P0 of 2026-10-30 ("at some points I can no longer make new terminals via Ctrl-` or Cmd-D"): a terminal
/// stand-in is taken back only on the daemon's answer or the connection's end, never on a client deadline. DEBUG
/// builds stop at such a rollback (`DaemonService.checkStandInRollback`); this pins what it judges.
@MainActor @Suite struct TerminalStandInRollbackInvariantTests {
    private let ctrlBacktick = Intent.createTab(pane: PaneID(rawValue: 3), provisional: ProvisionalTab().terminal(TerminalID.generate(), cwd: nil))
    private let cmdD = Intent.splitPane(pane: PaneID(rawValue: 3), direction: .right, ratio: 0.5, provisional: ProvisionalPane())

    @Test func aClientDeadlineNeverTakesATerminalStandInBack() {
        for intent in [ctrlBacktick, cmdD] {
            #expect(DaemonService.takesTerminalStandInBackOnClock(intent, error: DaemonError.terminalStartTimedOut("new-tab")))
            #expect(DaemonService.takesTerminalStandInBackOnClock(intent, error: DaemonError.timedOut("split")))
        }
    }

    @Test func theDaemonsRefusalOrTheConnectionsEndMayTakeItBack() {
        for intent in [ctrlBacktick, cmdD] {
            #expect(!DaemonService.takesTerminalStandInBackOnClock(intent, error: DaemonError.notConnected))
            #expect(!DaemonService.takesTerminalStandInBackOnClock(intent, error: DaemonError.command(cmd: "new-tab", message: "unknown pane 3", code: nil)))
        }
    }

    @Test func otherStandInsAreNotTerminalOnes() {
        let browser = Intent.createTab(pane: PaneID(rawValue: 3), provisional: ProvisionalTab().browser(url: "https://example.com", engine: "cef", profile: nil))
        #expect(!DaemonService.showsTerminalStandIn(browser))
    }
}
