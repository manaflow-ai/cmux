#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit
import CmuxNextDesign

/// `debug.agent_pane` crash_notice (child-crash-e2e.py, bd cx-d0d.2): the notice a page that keeps
/// crashing shows while it retries slowly (AgentPaneView+CrashNotice); it has no button.
extension AgentPaneView {
    /// The notice's texts (its message, and any button title), top to bottom; nil while no notice shows.
    public var debugCrashNoticeTexts: [String]? {
        guard let notice = crashNotice else { return nil }
        return notice.subviews.compactMap { ($0 as? any ShownText)?.stringValue ?? ($0 as? NSButton)?.title }
    }

    /// Reloads now, without waiting out the slow retry (the notice has no Reload button any more).
    /// False when no notice shows.
    public func debugPressCrashNoticeReload() -> Bool {
        guard crashNotice != nil else { return false }
        reloadAfterCrashes()
        return true
    }
}
#endif
