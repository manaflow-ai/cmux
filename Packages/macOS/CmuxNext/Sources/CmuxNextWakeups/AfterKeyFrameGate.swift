/// Holds the heavy content of a new object's stand-in until the frame of the key that made it committed, as
/// Chrome's new tab shows its strip item before its renderer attaches (TERMINAL CREATE COST, STATUS 11073: New
/// Terminal Tab took about 27 ms p50 to its commit because the key's turn also made the stand-in terminal's
/// Ghostty surface, host view and session). The first ask for a stand-in's content waits: the key's frame shows
/// the object selected on its themed pane, and right after that frame committed (``AfterFrameCommit``, no task,
/// timer or wait) `ready` is called with the key, so its owner asks again and makes the content in that pass.
/// Content that already exists, or that is no stand-in's, never waits.
///
/// ```swift
/// if gate.waits(tab.id, standIn: isProvisional) { return nil } // the pane shows its themed pane this frame
/// ```
@MainActor
public final class AfterKeyFrameGate {
    private var framed: Set<String> = []
    private var waiting: Set<String> = []
    private let afterFrame: (@escaping @MainActor () -> Void) -> Void
    /// Called with the key once its stand-in's frame committed: what shows it asks again.
    public var ready: ((String) -> Void)?

    /// - Parameter afterFrame: runs work after the current pass's frame committed (`AfterFrameCommit` in the app;
    ///   tests collect the work or run it at once).
    public init(afterFrame: @escaping (@escaping @MainActor () -> Void) -> Void) {
        self.afterFrame = afterFrame
    }

    /// Whether `key`'s content must not be made in this turn. The first ask for a stand-in (`standIn`) with no
    /// content yet (`exists` false) starts the wait; it lasts until the frame committed.
    public func waits(_ key: String, standIn: Bool, exists: Bool) -> Bool {
        if !exists, standIn, framed.insert(key).inserted {
            waiting.insert(key)
            afterFrame { [weak self] in if self?.waiting.remove(key) != nil { self?.ready?(key) } }
        }
        return waiting.contains(key)
    }

    /// `key` went (its tab closed): nothing waits for it any more.
    public func forget(_ key: String) {
        framed.remove(key)
        waiting.remove(key)
    }
}
