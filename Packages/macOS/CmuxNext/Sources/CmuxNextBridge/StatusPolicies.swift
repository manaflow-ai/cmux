public import CmuxNextDesign

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
    /// not start) counts as instant.
    ///
    /// - Parameters:
    ///   - run: The run that finished.
    ///   - visibility: Where its terminal is for the user now (`.hidden` when this client has no tab for it).
    /// - Returns: True when the run posts a notification.
    public func notifies(_ run: FinishedStatusRun, visibility: TerminalVisibility) -> Bool {
        let seconds = Double(run.durationMs ?? 0) / 1000
        guard seconds >= runNotifyMinimumSeconds else { return false }
        return runNotifyWhenVisible || !visibility.isVisible
    }
}
