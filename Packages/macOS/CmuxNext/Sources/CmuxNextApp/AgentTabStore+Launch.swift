import class CmuxNextDesign.LaunchReveal
import CmuxNextLaunch
import CmuxNextWakeups

extension AgentTabStore {
    /// Whether `key`'s view waits for the launch. A tab's view is a `WKWebView`, and
    /// the first one makes the `WKProcessPool` (about 150 ms on the main thread), so before startup
    /// completes a tab draws its picture and makes its view in an afterFirstFrame post of the launch's
    /// scheduler, the focused pane's tab first (``LaunchViewQueue``). A tab outside the focused pane,
    /// while that pane shows a terminal that will draw, posts only once the pane region is ready (the
    /// terminal's first content, `LaunchSettle`), so its view does not delay that terminal. A tab whose
    /// view exists, or shown after completion, makes its view at once. `show` runs once, in the post;
    /// the pane keeps the tab's picture meanwhile.
    ///
    /// - Parameters:
    ///   - key: The tab.
    ///   - focused: The tab shows in the window's focused pane.
    ///   - focusedTerminalDraws: The window's focused pane shows a terminal that will draw.
    ///   - reveal: The launch's reveal (`AppServices.launchReveal`), whose pane region gates the other panes' tabs.
    ///   - startup: The launch's scheduler (`AppServices.launchStartup`); nil in tests with no launch.
    ///   - show: Shows the tab again once its view may be made.
    /// - Returns: True when the view waits.
    func deferAtLaunch(_ key: String, focused: Bool, focusedTerminalDraws: Bool, reveal: LaunchReveal, startup: StartupScheduler?,
                       show: @escaping @MainActor () -> Void) -> Bool {
        guard views[resolve(key)] == nil else { return false }
        return launchDeferred.waitsAtLaunch(key, focused: focused, paneGate: focusedTerminalDraws ? reveal : nil,
                                            startup: startup, show: show)
    }
}
