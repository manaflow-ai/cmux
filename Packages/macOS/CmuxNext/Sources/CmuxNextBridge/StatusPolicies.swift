public import CmuxNextDesign
import CmuxNextWindowRules

/// Where a terminal is, as the client sees it: Lawrence's visibility rule
/// for run notifications (plans/cmux-next/status-indicators.md). Client view
/// state, so each client decides for itself.
public struct TerminalVisibility: Hashable, Sendable {
    /// The terminal's tab is the selected tab of its pane.
    public var tabSelected: Bool
    /// Its pane is on screen in its window (not scrolled off the strip).
    public var paneOnScreen: Bool
    /// Its window is key, or at least not occluded.
    public var windowShown: Bool
    /// cmux is the active app.
    public var appActive: Bool

    public init(tabSelected: Bool, paneOnScreen: Bool, windowShown: Bool, appActive: Bool) {
        self.tabSelected = tabSelected
        self.paneOnScreen = paneOnScreen
        self.windowShown = windowShown
        self.appActive = appActive
    }

    /// The user can see the terminal now.
    public var isVisible: Bool { tabSelected && paneOnScreen && windowShown && appActive }

    public static let hidden = TerminalVisibility(tabSelected: false, paneOnScreen: false, windowShown: false, appActive: false)
}

/// The client-side rules for status facts the daemon publishes raw.
extension StatusBehaviorSettings {
    /// Whether a finished `cmux status run` notifies: it ran at least
    /// `runNotifyMinimumSeconds`, and its terminal is not visible unless
    /// `runNotifyWhenVisible` is on. A run with no duration (its command could
    /// not start) counts as instant. The rule is Rust's (cmux-window-rules
    /// `status_alerts::run_notifies`, op `window_notifications_run_notifies`).
    ///
    /// - Parameters:
    ///   - run: The run that finished.
    ///   - visibility: Where its terminal is for the user now (`.hidden` when this client has no tab for it).
    /// - Returns: True when the run posts a notification.
    public func notifies(_ run: FinishedStatusRun, visibility: TerminalVisibility) -> Bool {
        struct Behavior: Encodable { var runNotifyMinimumSeconds: Double, runNotifyWhenVisible: Bool }
        struct Request: Encodable { var durationMs: UInt64?, behavior: Behavior, visibility: TerminalVisibility.Wire }
        struct Reply: Decodable { var notifies: Bool }
        let request = Request(durationMs: run.durationMs,
                              behavior: Behavior(runNotifyMinimumSeconds: runNotifyMinimumSeconds, runNotifyWhenVisible: runNotifyWhenVisible),
                              visibility: TerminalVisibility.Wire(visibility))
        // An FFI without the op answers nothing: the run posts nothing, as before runs notified.
        return WindowRules().call("window_notifications_run_notifies", request, as: Reply.self)?.notifies ?? false
    }
}

extension TerminalVisibility {
    /// Where a terminal is, as cmux-window-rules `status_alerts::Visibility` reads it.
    struct Wire: Encodable {
        var tabSelected: Bool, paneOnScreen: Bool, windowShown: Bool, appActive: Bool

        init(_ visibility: TerminalVisibility) {
            tabSelected = visibility.tabSelected
            paneOnScreen = visibility.paneOnScreen
            windowShown = visibility.windowShown
            appActive = visibility.appActive
        }
    }
}
