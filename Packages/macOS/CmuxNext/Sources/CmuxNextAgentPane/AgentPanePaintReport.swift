/// A page's paint report (`pane.painted`, ``AgentPaneRequest/painted(fromKeptTail:settled:)``), and what it
/// changes in the page's model.
struct AgentPanePaintReport {
    let fromKeptTail: Bool
    let settled: Bool

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
        model.markPainted()
    }
}
