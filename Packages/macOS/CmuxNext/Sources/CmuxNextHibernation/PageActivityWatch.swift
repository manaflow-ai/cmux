package import CmuxNextWakeups

/// Watches each hidden page's title and icon for ``PageBackgroundActivity``: one ``ServiceObservation``
/// per hidden page, from its hide to its show, discard or close, in the `background` class (a fact
/// for the discard planner nobody waits on; it must still be noted while the page is hidden).
/// Event-driven: a page that changes nothing wakes nothing, and a frozen page changes nothing.
///
/// Off until its owner sets ``isEnabled`` (the `memorySaverBackgroundActivity` feature): until then no
/// page is watched and none is ever active.
///
/// ```swift
/// let watch = PageActivityWatch(mainWork: mainWork)
/// watch.isEnabled = true
/// watch.hide("tab", look: { [weak page] in page.map(look(of:)) }, isAgentDriven: { false }, onActive: replan)
/// watch.contains("tab")   // after its title changes: true
/// watch.forget("tab")     // shown: false again
/// ```
@MainActor
package final class PageActivityWatch {
    /// Whether hidden pages are watched.
    package var isEnabled = false
    /// The facts the watches feed.
    package private(set) var activity = PageBackgroundActivity()
    private var observations: [String: ServiceObservation<PageBackgroundActivity.Look?>] = [:]
    private let mainWork: MainWorkScheduler

    /// - Parameter mainWork: The app's one main-thread scheduler: each change's note is a task on it.
    package init(mainWork: MainWorkScheduler) {
        self.mainWork = mainWork
    }

    /// Page `key` hid: watches what it shows from now on.
    ///
    /// - Parameters:
    ///   - key: The page.
    ///   - look: What the page shows now, read with observation tracking; nil once it is gone.
    ///   - isAgentDriven: Whether an agent drives the page now: its changes are the agent's, not
    ///     the page's (automation never competes with the person), and do not count.
    ///   - onActive: Runs on the change that made the page active (once per hidden period).
    package func hide(_ key: String, look: @escaping @MainActor @Sendable () -> PageBackgroundActivity.Look?,
                      isAgentDriven: @escaping @MainActor @Sendable () -> Bool = { false },
                      onActive: @escaping @MainActor @Sendable () -> Void) {
        forget(key)
        guard isEnabled, let shown = look() else { return }
        activity.hide(key, look: shown)
        // The observation applies the look now in this turn (the same as `shown`, so it notes no
        // change), then each later change of what `look` read once per flush.
        observations[key] = ServiceObservation(.background, owner: "hibernation.pageActivity", on: mainWork,
                                               read: look) { [weak self] current in
            guard let self else { return }
            guard let current else { return self.endWatch(key) }
            if self.activity.note(key, look: current, counts: !isAgentDriven()) { onActive() }
        }
    }

    /// The page is gone: its watch ends, its fact stays until ``forget(_:)``.
    private func endWatch(_ key: String) {
        observations.removeValue(forKey: key)?.cancel()
    }

    /// Whether hidden page `key` changed its title or icon since it hid.
    package func contains(_ key: String) -> Bool {
        activity.contains(key)
    }

    /// Page `key` showed, was discarded or closed: its watch and its fact end.
    package func forget(_ key: String) {
        observations.removeValue(forKey: key)?.cancel()
        activity.forget(key)
    }

    /// Ends every watch (the owner stops).
    package func stop() {
        for key in Array(observations.keys) { forget(key) }
    }
}
