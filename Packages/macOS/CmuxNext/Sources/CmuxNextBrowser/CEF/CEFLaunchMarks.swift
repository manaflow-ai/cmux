/// The browser pane's launch marks: `browser_pane.first_paint`, the first page a person sees in a Chromium tab
/// presented its first frame (``CEFTab/documentPainted``), and `browser_pane.input_ready`, the first such page took
/// keys (``CEFTab/onReadyForKeys``). A tab an agent drives, one not in front and a blank New Tab page count for neither.
/// The tab reports them through ``CEFTab/onLaunchMark``, which the App points at its launch-mark log (that log keeps the
/// first time per name, so each is once per launch). scripts/ci/launch_tti_check.py reads them beside the terminal's
/// `first_terminal_frame` and `terminal_echo` and the chat's `agent_pane.painted` and `agent_pane.input_echoed`.
///
/// Leo, 2026-11-22: "the speed i see on restarts is terminal << chromium browser <<<<<<<< our [...] agent
/// pane."
public struct CEFLaunchMarks {
    public init() {}
    public static let firstPaint = "browser_pane.first_paint"
    public static let inputReady = "browser_pane.input_ready"

    /// Whether a tab's page counts: one a person opened (not an agent's), in front, showing a real page.
    static func counts(agentDriven: Bool, inFront: Bool, blank: Bool) -> Bool {
        !agentDriven && inFront && !blank
    }
}

extension CEFTab {
    /// Reports `name` to ``onLaunchMark`` when this tab's page counts (``CEFLaunchMarks/counts``).
    func reportLaunchMark(_ name: String) {
        guard let onLaunchMark, CEFLaunchMarks.counts(agentDriven: isAgentDriven, inFront: host.visibleTab === self, blank: blankIsDocument) else { return }
        onLaunchMark(name)
    }
}
