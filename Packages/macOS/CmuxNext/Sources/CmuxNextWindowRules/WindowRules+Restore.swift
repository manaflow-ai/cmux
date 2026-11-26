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

/// Saved windows a launch has not made yet, front to back (``WindowRules/restoredLater(_:adopted:)``). After the front
/// window's frame each comes back in its own main-thread turn (``start(make:stopped:done:)``); a show aimed at one makes
/// it at once (``makeNow(_:)``).
@MainActor public final class DeferredWindows {
    private var waiting: [String] = []
    private var make: ((String) -> Void)?
    private let afterFrame: (@escaping @MainActor () -> Void) -> Void
    /// Runs at ``start(make:stopped:done:)``, before any waiting window is made (tests: what the restore made alone).
    public var onStart: (() -> Void)?

    /// `afterFrame`: runs its work once the current pass's frame committed (the app's `AfterFrameCommit`).
    public init(afterFrame: @escaping (@escaping @MainActor () -> Void) -> Void) {
        self.afterFrame = afterFrame
    }

    public var isEmpty: Bool { waiting.isEmpty }

    public func contains(_ id: String) -> Bool { waiting.contains(id) }

    /// These wait, in this order (set before the restore makes its windows, so it skips them).
    public func queue(_ ids: [String]) { waiting = ids }

    /// Makes the waiting windows, one per turn after a frame commit. `make` makes one (a gone or closed one makes
    /// nothing and the next goes in the same turn); `stopped` drops the rest (a quit); `done` runs once none waits.
    public func start(make: @escaping (String) -> Bool, stopped: @escaping () -> Bool, done: @escaping () -> Void) {
        self.make = { _ = make($0) }
        onStart?()
        guard !waiting.isEmpty else { return done() }
        step(make: make, stopped: stopped, done: done)
    }

    /// Makes window `id` now when it waits and the queue started (before that the restore is still placing windows,
    /// and it stays queued); whether it was made.
    @discardableResult
    public func makeNow(_ id: String) -> Bool {
        guard make != nil, let index = waiting.firstIndex(of: id) else { return false }
        waiting.remove(at: index)
        make?(id)
        return true
    }

    private func step(make: @escaping (String) -> Bool, stopped: @escaping () -> Bool, done: @escaping () -> Void) {
        afterFrame { [weak self] in
            guard let self else { return }
            if stopped() { return waiting.removeAll() }
            while !waiting.isEmpty, !make(waiting.removeFirst()) {}
            if waiting.isEmpty { return done() }
            step(make: make, stopped: stopped, done: done)
        }
    }
}
