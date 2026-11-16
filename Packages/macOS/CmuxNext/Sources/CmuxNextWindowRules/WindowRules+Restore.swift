/// Which saved windows a launch makes before its front window is live (cmux-window-rules `restore`;
/// cmuxterm-hq docs/design/launch-shell-first.md, stage 1: only what is visible).
extension WindowRules {
    /// One saved window, in the registry's recency order (front first).
    public nonisolated struct SavedWindow: Encodable, Equatable, Sendable {
        var id: String
        var open: Bool
        var made: Bool

        /// `open`: open in the saved registry; `made`: it already has its window (the launch window took its id).
        public init(id: String, open: Bool, made: Bool) {
            self.id = id
            self.open = open
            self.made = made
        }
    }

    /// The saved windows the launch makes after its front window, front to back: every open one without a window but
    /// the front (`adopted`, the window the launch window became, else the front open one). None when the FFI does
    /// not answer: then every window is made with the restore, as before.
    public func restoredLater(_ windows: [SavedWindow], adopted: String?) -> [String] {
        struct Request: Encodable { var windows: [SavedWindow], adopted: String? }
        struct Reply: Decodable { var later: [String] }
        return call("window_restore_order", Request(windows: windows, adopted: adopted), as: Reply.self)?.later ?? []
    }
}

/// Saved windows a launch has not made yet, front to back (``WindowRules/restoredLater(_:adopted:)``): they come
/// back one per main-thread turn after the front window's frame, and a show aimed at one makes it at once.
public struct DeferredWindows: Sendable {
    public private(set) var waiting: [String] = []

    public init() {}

    public var isEmpty: Bool { waiting.isEmpty }

    public func contains(_ id: String) -> Bool { waiting.contains(id) }

    /// The launch's order: these wait, in this order.
    public mutating func wait(_ ids: [String]) { waiting = ids }

    /// Takes `id` out (it is made now, or gone); whether it was waiting.
    @discardableResult
    public mutating func take(_ id: String) -> Bool {
        guard let index = waiting.firstIndex(of: id) else { return false }
        waiting.remove(at: index)
        return true
    }

    /// The next window to make, taken out; nil when none waits.
    public mutating func next() -> String? { waiting.isEmpty ? nil : waiting.removeFirst() }

    public mutating func removeAll() { waiting.removeAll() }
}
