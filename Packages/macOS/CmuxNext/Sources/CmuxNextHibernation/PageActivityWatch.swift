import CmuxNextCompat

/// Watches each hidden page's title and icon for ``PageBackgroundActivity``: one observation per
/// hidden page, from its hide to its show, discard or close. Event-driven: a page that changes
/// nothing wakes nothing, and a frozen page changes nothing.
///
/// Off until its owner sets ``isEnabled`` (the `memorySaverBackgroundActivity` feature): until then no
/// page is watched and none is ever active.
///
/// ```swift
/// let watch = PageActivityWatch()
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
    private var observations: [String: Task<Void, Never>] = [:]

    package init() {}

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
        // The stream's first value is the look now: a change between this hide and the task's
        // first turn is a change against `shown`, so none is lost.
        let looks = ObservationStream(look)
        observations[key] = Task { [weak self] in
            for await current in looks {
                guard let self, let current else { return }
                if self.activity.note(key, look: current, counts: !isAgentDriven()) { onActive() }
            }
        }
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
