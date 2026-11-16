import os

/// How each window's creation holds ended, by window number (the app's `CreationInputCoordinator` keeps one; tests and
/// `debug.focus` read it).
public nonisolated struct CreationHoldLog: Equatable, Sendable {
    /// Windows whose current hold had a creation that failed: its unforced end is ``CreationHoldEnd/creationFailed``.
    private var failedCreation: Set<Int> = []
    /// The last end of each window's hold.
    public private(set) var last: [Int: CreationHoldEnd] = [:]

    /// How many keys of each window's last hold were lost: typed for a terminal, and typed into no terminal
    /// (``noteEnded(_:window:keys:lastAction:untyped:)``).
    public private(set) var lostKeys: [Int: Int] = [:]
    /// Held keys that ran again for a terminal that was gone, since the last hold's end began (``wentWithTerminal(_:)``).
    private var gone = 0

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
    /// `count` held keys ran again for a terminal that has no view, no tab and no id that a create's reply named: the
    /// person closed it. (A New Terminal Tab's keys whose stand-in left the pane and whose tab the store does not list yet
    /// are not here: they go to the made terminal by its id.) They are typed into no terminal: lost. The end of the hold
    /// that gave them out counts them (``lostKeys``).
    public mutating func wentWithTerminal(_ count: Int) {
        gone += count
        Self.logger.notice("\(count, privacy: .public) held key(s) went with their closed terminal")
    }

    /// Logs a hold of `window` that ended `end` with `keys` held keys going on now (`lastAction`: the router's last action),
    /// after those keys ran again, and keeps its count of lost keys (``lostKeys``).
    /// `untyped`: keys for a new terminal that no terminal could take and that are lost (``CreationInputBuffer/untypedTerminalKeys``):
    /// a new workspace's the window does not show, or a New Terminal Tab's whose tab the store never listed. The count adds
    /// the keys that this end gave to a terminal that was gone (``wentWithTerminal(_:)``). Each end that has some says so.
    public mutating func noteEnded(_ end: CreationHoldEnd, window: Int, keys: Int, lastAction: String?, untyped stranded: Int = 0) {
        let untyped = stranded + gone
        lostKeys[window] = untyped
        gone = 0
        if end == .replyBoundReached {
            // cmux-ad m12: a creation whose reply never came keeps the person's keys no longer.
            return Self.logger.notice("creation hold of window \(window, privacy: .public) ended at its reply bound: \(keys, privacy: .public) held key(s) go on now, \(untyped, privacy: .public) for a new terminal had no terminal to go to")
        }
        guard end == .limitReached else {
            if untyped > 0 { Self.logger.notice("creation hold of window \(window, privacy: .public) ended: \(untyped, privacy: .public) key(s) for a new terminal had no terminal to go to and are lost") }
            return
        }
        // The person's keys for a new terminal waited the whole bound and go on now, each to the terminal it was typed for.
        Self.logger.notice("creation hold of window \(window, privacy: .public) ended at its limit, not on focus: \(keys, privacy: .public) held key(s) go on now, \(untyped, privacy: .public) for a new terminal had no terminal to go to and are lost; last action \(lastAction ?? "-", privacy: .public)")
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "focus.creation-hold")

    public mutating func end(in window: Int, forced: CreationHoldEnd?, pageTab: String? = nil) -> CreationHoldEnd {
        gone = 0 // the keys that this end gives out are counted from here
        let failed = failedCreation.remove(window) != nil
        let end = forced ?? (failed ? .creationFailed : .focusLanded)
        if end == .limitReached, let pageTab { pageExpired.insert(pageTab) }
        last[window] = end
        return end
    }
}
