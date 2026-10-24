#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit
import CmuxNextDesign

/// `debug.agent_pane` crash_notice (child-crash-e2e.py, bd cx-d0d.2): the notice a page that keeps
/// crashing shows instead of reloading (AgentPaneView+CrashNotice), and its Reload button.
extension AgentPaneView {
    /// The notice's message and button titles, top to bottom; nil while no notice shows.
    public var debugCrashNoticeTexts: [String]? {
        guard let notice = crashNotice else { return nil }
        return notice.subviews.compactMap { ($0 as? any ShownText)?.stringValue ?? ($0 as? NSButton)?.title }
    }

    /// Presses the notice's Reload button, as a click does. False when no notice shows.
    public func debugPressCrashNoticeReload() -> Bool {
        guard let button = crashNotice?.subviews.compactMap({ $0 as? NSButton }).first else { return false }
        button.performClick(nil)
        return true
    }
}
#endif
