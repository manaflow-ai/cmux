/// Holds the heavy content of a new object's stand-in until the frame of the key that made it committed, as
/// Chrome's new tab shows its strip item before its renderer attaches (TERMINAL CREATE COST, STATUS 11073: New
/// Terminal Tab took about 27 ms p50 to its commit because the key's turn also made the stand-in terminal's
/// Ghostty surface, host view and session). The first ask for a stand-in's content waits: the key's frame shows
/// the object selected on its themed pane, and right after that frame committed (``AfterFrameCommit``, no task,
/// timer or wait) its asker shows it again and makes the content in that pass.
/// Content that already exists, or that is no stand-in's, never waits.
///
/// ```swift
/// if gate.waits(tab.id, standIn: isProvisional, exists: hasView, showAgain: showSelected) { return nil } // its themed pane
/// ```
@MainActor
public final class AfterKeyFrameGate {
    private var framed: Set<String> = []
    /// The stand-ins waiting for their key's frame, each with what shows it again.
    private var waiting: [String: @MainActor () -> Bool] = [:]
    private let afterFrame: (@escaping @MainActor () -> Void) -> Void

    /// - Parameter afterFrame: runs work after the current pass's frame committed (`AfterFrameCommit` in the app;
    ///   tests collect the work and run it later). It must not run the work inside the call: the wait starts first.
    public init(afterFrame: @escaping (@escaping @MainActor () -> Void) -> Void) {
        self.afterFrame = afterFrame
    }

    /// Whether `key`'s content must not be made in this turn. The first ask for a stand-in (`standIn`) with no
    /// content yet (`exists` false) starts the wait; it lasts until the frame committed, whatever later asks say. Then `showAgain` (the
    /// latest asker's) runs and answers whether anything still shows the stand-in; nothing does (it closed or
    /// another tab was selected): the key is forgotten, so a later show waits for its own frame.
    public func waits(_ key: String, standIn: Bool, exists: Bool, showAgain: @escaping @MainActor () -> Bool) -> Bool {
        if waiting[key] != nil { waiting[key] = showAgain }
        guard !exists, standIn, framed.insert(key).inserted else { return waiting[key] != nil }
        waiting[key] = showAgain
        afterFrame { [weak self] in
            guard let self, let show = waiting.removeValue(forKey: key), !show() else { return }
            framed.remove(key)
        }
        return true
    }

    /// `key` went (its tab closed): nothing waits for it any more.
    public func forget(_ key: String) {
        framed.remove(key)
        waiting[key] = nil
    }
}
