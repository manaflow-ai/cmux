/// A page's paint report (`pane.painted`, ``AgentPaneRequest/painted(fromKeptTail:settled:appliedWake:)``), and
/// what it changes in the page's model.
struct AgentPanePaintReport {
    let fromKeptTail: Bool
    let settled: Bool
    /// The page took the state of its adopt event (``AgentPaneView/adoptSession(_:tab:revealTurn:wake:moved:)``).
    let appliedWake: Bool

    func apply(to model: AgentPaneModel) {
        AgentPaneLaunchTimings.shared.mark(model.newTab != nil ? "agent_pane.newtab_painted" : "agent_pane.painted")
        // The first report only, and before `markPainted`: the pane's loading state leaves on
        // that call, and what that frame drew is what decides whether the page fades in
        // (``AgentPaneView/pageFades``). A later report describes a frame nothing is waiting on.
        if !model.hasPainted {
            model.paintedFromKeptTail = fromKeptTail
            model.paintedSettled = settled
            model.pageReportedPaint = true
        }
        // The page holds the state now: from here its own answers say what it holds, and the state
        // is handed out, as a handshake's is.
        if appliedWake, let wake = model.pendingWake {
            model.handedWake = wake
            model.pendingWake = nil
        }
        model.markPainted()
    }
}
