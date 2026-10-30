/// Why a window's creation hold ended (R-L5: its end is a signal). `focusLanded`: every creation of the hold replied
/// and the focus it asked for holds, with a responder that takes the keys. `limitReached`: the hold's 2 s bound ended
/// it first, so the keys typed for the new terminal went on up to that late; logged, as a person feels it.
/// `focusLeft`: a key went to a field outside the content (a sidebar or bar field), which ends any hold. `windowClosed`.
/// `creationFailed`: a creation of the hold failed (the daemon refused it, or the connection ended); no focus landed.
public nonisolated enum CreationHoldEnd: Equatable, Sendable {
    case focusLanded, limitReached, focusLeft, windowClosed, creationFailed
}

/// How each window's creation holds ended, by window number (the app's `CreationInputCoordinator` keeps one; tests and
/// `debug.focus` read it).
public nonisolated struct CreationHoldLog: Equatable, Sendable {
    /// Windows whose current hold had a creation that failed: its unforced end is ``CreationHoldEnd/creationFailed``.
    private var failedCreation: Set<Int> = []
    /// The last end of each window's hold.
    public private(set) var last: [Int: CreationHoldEnd] = [:]

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
    public mutating func end(in window: Int, forced: CreationHoldEnd?) -> CreationHoldEnd {
        let failed = failedCreation.remove(window) != nil
        let end = forced ?? (failed ? .creationFailed : .focusLanded)
        last[window] = end
        return end
    }
}
