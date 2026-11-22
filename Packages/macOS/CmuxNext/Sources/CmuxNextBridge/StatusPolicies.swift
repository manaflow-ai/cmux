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
    /// Whether a shell command running since `sinceMs` shows as busy at
    /// `nowMs` (`status.inferCommandBusy`, `status.inferCommandBusyAfter`).
    public func showsCommandBusy(sinceMs: UInt64, nowMs: UInt64) -> Bool {
        guard inferCommandBusy else { return false }
        return nowMs >= sinceMs &+ commandBusyThresholdMs
    }

    /// When a command that is not shown yet will be (the client arms one
    /// one-shot timer for it, never a poll). Nil when it shows already or
    /// never will.
    public func commandBusyDeadlineMs(sinceMs: UInt64, nowMs: UInt64) -> UInt64? {
        guard inferCommandBusy else { return nil }
        let deadline = sinceMs &+ commandBusyThresholdMs
        return nowMs < deadline ? deadline : nil
    }

    /// Whether a finished `cmux status run` posts a notification: it took
    /// at least `status.runNotifyMinimumSeconds` and its terminal is not
    /// visible (unless `status.runNotifyWhenVisible`).
    public func notifiesFinishedRun(durationMs: UInt64, visibility: TerminalVisibility) -> Bool {
        guard Double(durationMs) >= runNotifyMinimumSeconds * 1000 else { return false }
        return runNotifyWhenVisible || !visibility.isVisible
    }

    var commandBusyThresholdMs: UInt64 {
        UInt64(max(0, inferCommandBusyAfter) * 1000)
    }
}
