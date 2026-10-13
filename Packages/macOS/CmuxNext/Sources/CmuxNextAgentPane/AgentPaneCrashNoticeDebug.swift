#if DEBUG
public import AppKit

/// `debug.agent_pane` crash_notice (child-crash-e2e.py, bd cx-d0d.2): the notice a page that keeps
/// crashing shows instead of reloading (AgentPaneView+CrashNotice), and its Reload button.
@MainActor
public enum AgentPaneCrashNoticeDebug {
    /// The notice's message and button titles, top to bottom; nil while no notice shows.
    public static func texts(_ view: AgentPaneView) -> [String]? {
        guard let notice = view.crashNotice else { return nil }
        return notice.subviews.compactMap { ($0 as? NSTextField)?.stringValue ?? ($0 as? NSButton)?.title }
    }

    /// Presses the notice's Reload button, as a click does. False when no notice shows.
    public static func pressReload(_ view: AgentPaneView) -> Bool {
        guard let button = view.crashNotice?.subviews.compactMap({ $0 as? NSButton }).first else { return false }
        button.performClick(nil)
        return true
    }
}
#endif
