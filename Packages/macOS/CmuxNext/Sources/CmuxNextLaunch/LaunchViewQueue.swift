public import CmuxNextWakeups

/// The web views of the tabs a launch shows before its first frame (p08-startup-042). Each tab's
/// picture (its page from the last quit) draws in the first frame; its view, a `WKWebView` whose first
/// one also makes the `WKProcessPool` (about 150 ms of main thread), is made in an afterFirstFrame post
/// of the launch's ``StartupScheduler``. There is one post per waiting tab, and each post makes the next
/// tab in the focused pane first, then the others in the order they asked. Chrome likewise paints the
/// browser window first and loads the restored tabs after it, the visible one first
/// (chrome/browser/sessions/session_restore.cc, `TabLoader`).
///
/// A view asked for after the first frame was committed (or missed, or once quit began) is made at once;
/// a tab that already waits keeps its place. Tests with no launch pass no scheduler: every view is made
/// at once.
///
/// ```swift
/// if queue.waitsForFirstFrame(key, focused: pane == focusedPane, startup: services.launchStartup, show: {
///     pane.showSelected()
/// }) {
///     return nil // the pane draws the tab's picture meanwhile
/// }
/// ```
@MainActor
public final class LaunchViewQueue {
    private struct Waiting {
        let key: String
        let focused: Bool
        let show: @MainActor () -> Void
    }

    private var waiting: [Waiting] = []

    public init() {}

    /// Whether `key`'s view waits for its afterFirstFrame post.
    ///
    /// - Parameter key: The tab.
    /// - Returns: True while the tab waits.
    public func isWaiting(_ key: String) -> Bool {
        waiting.contains { $0.key == key }
    }

    /// Whether `key`'s view waits for the first frame. Before the first frame the tab joins the queue
    /// and posts one afterFirstFrame task; that task shows the next waiting tab, the focused pane's first.
    ///
    /// - Parameters:
    ///   - key: The tab.
    ///   - focused: The tab shows in the focused pane, so its view is made before the others'.
    ///   - startup: The launch's scheduler; nil (a test with no launch) makes every view at once.
    ///   - show: Shows the tab again, now with its view; it runs once, in one of the queue's posts.
    /// - Returns: True when the view waits (the caller draws the tab's picture); false to make it now.
    public func waitsForFirstFrame(_ key: String, focused: Bool, startup: StartupScheduler?,
                                   show: @escaping @MainActor () -> Void) -> Bool {
        if isWaiting(key) { return true }
        guard let startup, startup.log.phase == .beforeFirstFrame else { return false }
        waiting.append(Waiting(key: key, focused: focused, show: show))
        startup.post(.afterFirstFrame, "AgentTabs.launchView", on: .main) { [weak self] in self?.showNext() }
        return true
    }

    /// Shows the next waiting tab: the first one in the focused pane, else the first one.
    private func showNext() {
        guard let index = waiting.firstIndex(where: \.focused) ?? waiting.indices.first else { return }
        let next = waiting.remove(at: index)
        next.show()
    }
}
