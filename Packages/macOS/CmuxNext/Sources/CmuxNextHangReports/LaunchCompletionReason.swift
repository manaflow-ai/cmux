/// Why a launch reached `startup_complete`, as a report counts it: the StartupScheduler's reasons
/// (plans/cmux-next/chrome-parity/p08-startup.md, task 013), like Chrome's
/// `Startup.BrowserStartupCompleteReason` (`chrome/browser/after_startup_task_utils.cc`). A launch
/// that keeps reaching ``failsafe`` is a stuck daemon or a bug; this count makes it visible.
public nonisolated enum LaunchCompletionReason: String, Codable, Sendable, CaseIterable {
    /// Every visible pane showed loaded content (the normal launch).
    case visiblePaneLoadedIdle
    /// A visible pane did not load within its 5 s bound.
    case visiblePaneTimedOut
    /// Windows opened, but no pane in them was visible.
    case noVisiblePane
    /// Restore showed no window.
    case noWindow
    /// The daemon could not be reached, so no pane could load.
    case daemonUnavailable
    /// The 10 s failsafe fired before every startup ref was released.
    case failsafe
}
