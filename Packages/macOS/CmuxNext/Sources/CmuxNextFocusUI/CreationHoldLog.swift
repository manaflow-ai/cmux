import os

/// How each window's creation holds ended, by window number (the app's `CreationInputCoordinator` keeps one; tests and
/// `debug.focus` read it).
public nonisolated struct CreationHoldLog: Equatable, Sendable {
    /// Windows whose current hold had a creation that failed: its unforced end is ``CreationHoldEnd/creationFailed``.
    private var failedCreation: Set<Int> = []
    /// The last end of each window's hold.
    public private(set) var last: [Int: CreationHoldEnd] = [:]

    /// Tabs whose page hold ended at its bound: their page may never come, so no new page hold opens for them.
    public private(set) var pageExpired: Set<String> = []

    /// `tab`'s page exists: a later cold show of it may hold its keys again.
    public mutating func pageArrived(_ tab: String) { pageExpired.remove(tab) }

    public init() {}

    /// A creation of `window`'s current hold failed.
    public mutating func creationFailed(in window: Int) { failedCreation.insert(window) }

    /// `window` is gone, and its hold with it.
    public mutating func windowClosed(_ window: Int) {
        failedCreation.remove(window)
        last[window] = .windowClosed
    }

    /// `window`'s hold ends now: by `forced` (its limit, the focus left the content), else on its own, as
    /// ``CreationHoldEnd/creationFailed`` when a creation of it failed and ``CreationHoldEnd/focusLanded`` otherwise.
    /// `pageTab`: the page a page hold waited for; ended at its limit, no new page hold opens for it (``pageExpired``).
    /// Logs a hold of `window` that ended `end` with `keys` held keys going on now (`lastAction`: the router's last action).
    /// `untyped`: keys for a new workspace's terminal that no terminal could take (``CreationInputBuffer/untypedTerminalKeys``).
    public static func noteEnded(_ end: CreationHoldEnd, window: Int, keys: Int, lastAction: String?, untyped: Int = 0) {
        if end == .replyBoundReached {
            // cmux-ad m12: a creation whose reply never came keeps the person's keys no longer.
            return logger.notice("creation hold of window \(window, privacy: .public) ended at its reply bound: \(keys, privacy: .public) held key(s) go on now, \(untyped, privacy: .public) for a new terminal had no terminal to go to")
        }
        guard end == .limitReached else { return }
        // The person's keys for a new terminal waited the whole bound and go on now, each to the terminal it was typed for.
        logger.notice("creation hold of window \(window, privacy: .public) ended at its limit, not on focus: \(keys, privacy: .public) held key(s) go on now; last action \(lastAction ?? "-", privacy: .public)")
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "focus.creation-hold")

    public mutating func end(in window: Int, forced: CreationHoldEnd?, pageTab: String? = nil) -> CreationHoldEnd {
        let failed = failedCreation.remove(window) != nil
        let end = forced ?? (failed ? .creationFailed : .focusLanded)
        if end == .limitReached, let pageTab { pageExpired.insert(pageTab) }
        last[window] = end
        return end
    }
}
