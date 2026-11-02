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
    public mutating func end(in window: Int, forced: CreationHoldEnd?, pageTab: String? = nil) -> CreationHoldEnd {
        let failed = failedCreation.remove(window) != nil
        let end = forced ?? (failed ? .creationFailed : .focusLanded)
        if end == .limitReached, let pageTab { pageExpired.insert(pageTab) }
        last[window] = end
        return end
    }
}
