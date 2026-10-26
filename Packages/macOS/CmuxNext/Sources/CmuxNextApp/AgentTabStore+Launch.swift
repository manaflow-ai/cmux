import CmuxNextLaunch
import CmuxNextWakeups

extension AgentTabStore {
    /// Whether `key`'s view waits for the launch's first frame (p08-startup-042). A tab's view is a
    /// `WKWebView`, and the first one makes the `WKProcessPool` (about 150 ms on the main thread), so a
    /// tab shown before the first frame draws its picture in that frame and makes its view in an
    /// afterFirstFrame post of the launch's scheduler, the focused pane's tab first (``LaunchViewQueue``).
    /// A tab whose view exists, or shown after the first frame, makes its view at once. `show` runs
    /// once, in the post; the pane keeps the tab's picture meanwhile.
    ///
    /// - Parameters:
    ///   - key: The tab.
    ///   - focused: The tab shows in the window's focused pane.
    ///   - startup: The launch's scheduler (`AppServices.launchStartup`); nil in tests with no launch.
    ///   - show: Shows the tab again once its view may be made.
    /// - Returns: True when the view waits.
    func deferAtLaunch(_ key: String, focused: Bool, startup: StartupScheduler?, show: @escaping @MainActor () -> Void) -> Bool {
        guard views[resolve(key)] == nil else { return false }
        return launchDeferred.waitsForFirstFrame(key, focused: focused, startup: startup, show: show)
    }
}
