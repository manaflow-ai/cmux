public import CmuxNextDaemon

/// R3 (principled-audit, P0 2026-10-30, "at some points I can no longer make new terminals via Ctrl-` or Cmd-D"): a
/// terminal stand-in (Ctrl-`'s new tab, Cmd-D's split pane) either becomes the daemon's terminal or stays pending in
/// view. It is taken back only on the daemon's own answer (a refusal) or the connection's end, never on a client
/// deadline: the daemon may still make the terminal, and the keys typed for it then reach another one.
extension DaemonService {
    /// Whether `intent` shows a terminal stand-in: a New Terminal Tab's provisional tab or a terminal split's pane
    /// (a conversation split's pane carries its page tab).
    public nonisolated static func showsTerminalStandIn(_ intent: Intent) -> Bool {
        switch intent {
        case .createTab(_, let provisional): provisional.kind == .pty
        case .splitPane(_, _, _, let provisional): provisional.tab == nil
        case .createWorkspace(let provisional, _): provisional.tab.kind == .pty
        default: false
        }
    }

    /// Whether `error` is the client's own deadline, not the daemon's answer and not the connection's end.
    public nonisolated static func isClientDeadline(_ error: any Error) -> Bool {
        switch error as? DaemonError {
        case .timedOut?, .terminalStartTimedOut?: true
        default: false
        }
    }

    /// Whether taking `intent` back for `error` breaks the invariant above.
    public nonisolated static func takesTerminalStandInBackOnClock(_ intent: Intent, error: any Error) -> Bool {
        showsTerminalStandIn(intent) && isClientDeadline(error)
    }

    /// DEBUG builds stop at a rollback that breaks the invariant (the journeys check the same end to end).
    nonisolated static func checkStandInRollback(_ intent: Intent, error: any Error, label: String) {
        #if DEBUG
        // crash-allow: DEBUG-only invariant check (R3); a release build keeps the rollback and logs it
        if takesTerminalStandInBackOnClock(intent, error: error) {
            assertionFailure("R3: \(label) took a terminal stand-in back on a client deadline; the daemon may still make it: \(error)")
        }
        #endif
    }
}
