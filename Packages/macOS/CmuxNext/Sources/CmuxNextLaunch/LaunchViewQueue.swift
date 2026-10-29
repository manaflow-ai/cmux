public import class CmuxNextDesign.LaunchReveal
public import CmuxNextWakeups

/// The web views of the agent tabs a launch shows before startup completes. Each
/// tab's picture (its page from the last quit) draws first; its view, a `WKWebView` whose first one
/// also makes the `WKProcessPool` (about 150 ms of main thread), is made only in an afterFirstFrame
/// post of the launch's ``StartupScheduler``, so before completion these posts are the only makers of
/// agent tab views. There is one post per waiting tab, and each post makes the next tab in the focused
/// pane first, then the others in the order they asked. Chrome likewise paints the browser window
/// first and loads the restored tabs after it, the visible one first
/// (chrome/browser/sessions/session_restore.cc, `TabLoader`).
///
/// A tab outside the focused pane, while that pane shows a terminal that will draw, also waits for
/// the pane region (``LaunchReveal``, the focused terminal's first content or the reveal deadline)
/// before its post: its view would otherwise delay that terminal's first content.
///
/// A view asked for after completion, or once quit began, is made at once; a tab that already waits
/// keeps its place. Tests with no launch pass no scheduler: every view is made at once.
///
/// ```swift
/// if queue.waitsAtLaunch(key, focused: pane == focusedPane, paneGate: focusedTerminalDraws ? reveal : nil,
///                        startup: services.launchStartup, show: { pane.showSelected() }) {
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

    /// Tabs whose post is pending.
    private var posted: [Waiting] = []
    /// Tabs outside the focused pane that wait for the pane region before their post.
    private var held: [Waiting] = []
    /// The pane region's waiter is registered (``LaunchReveal/whenReady(_:_:)``).
    private var paneGateArmed = false

    public init() {}

    /// Whether `key`'s view waits for its launch post.
    ///
    /// - Parameter key: The tab.
    /// - Returns: True while the tab waits.
    public func isWaiting(_ key: String) -> Bool {
        posted.contains { $0.key == key } || held.contains { $0.key == key }
    }

    /// Whether `key`'s view waits for the launch. Before completion the tab joins the queue and posts
    /// one afterFirstFrame task (after the pane region, with a `paneGate`); that task shows the next
    /// waiting tab, the focused pane's first.
    ///
    /// - Parameters:
    ///   - key: The tab.
    ///   - focused: The tab shows in the focused pane, so its view is made before the others'.
    ///   - paneGate: For a tab outside the focused pane while that pane shows a terminal that will
    ///     draw: the launch's reveal, whose pane region the tab's post waits for. Nil otherwise.
    ///   - startup: The launch's scheduler; nil (a test with no launch) makes every view at once.
    ///   - show: Shows the tab again, now with its view; it runs once, in one of the queue's posts.
    /// - Returns: True when the view waits (the caller draws the tab's picture); false to make it now.
    public func waitsAtLaunch(_ key: String, focused: Bool, paneGate: LaunchReveal?, startup: StartupScheduler?,
                              show: @escaping @MainActor () -> Void) -> Bool {
        if isWaiting(key) { return true }
        guard let startup else { return false }
        switch startup.log.phase {
        case .beforeFirstFrame, .afterFirstFrame: break
        case .complete, .quitting: return false
        }
        let entry = Waiting(key: key, focused: focused, show: show)
        guard !focused, let paneGate, !paneGate.isReady(.pane) else {
            post(entry, on: startup)
            return true
        }
        held.append(entry)
        if !paneGateArmed {
            paneGateArmed = true
            paneGate.whenReady(.pane) { [weak self] in self?.releaseHeld(on: startup) }
        }
        return true
    }

    private func post(_ entry: Waiting, on startup: StartupScheduler) {
        posted.append(entry)
        startup.post(.afterFirstFrame, "AgentTabs.launchView", on: .main) { [weak self] in self?.showNext() }
    }

    /// The pane region is ready: each held tab posts its task.
    private func releaseHeld(on startup: StartupScheduler) {
        paneGateArmed = false
        let released = held
        held = []
        for entry in released { post(entry, on: startup) }
    }

    /// Shows the next posted tab: the first one in the focused pane, else the first one.
    private func showNext() {
        guard let index = posted.firstIndex(where: \.focused) ?? posted.indices.first else { return }
        let next = posted.remove(at: index)
        next.show()
    }
}
