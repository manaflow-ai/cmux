import CmuxNextCompat

/// A memory pressure source the test drives: ``send(_:)`` delivers a level as the kernel's source
/// would (on the main actor, at once), until the ``MemoryPressureEvents`` holding it cancels it.
nonisolated final class ManualMemoryPressureSource: MemoryPressureSource {
    private nonisolated struct State {
        var deliver: (@MainActor @Sendable (MemoryPressureLevel) -> Void)?
        var isCancelled = false
    }

    // The events start and cancel the source on whichever thread runs their init and deinit; a test sends on main.
    private let state = Mutex(State())

    func start(delivering deliver: @escaping @MainActor @Sendable (MemoryPressureLevel) -> Void) {
        state.withLock { $0.deliver = deliver }
    }

    func cancel() {
        state.withLock { $0.isCancelled = true }
    }

    /// Whether the events cancelled the source.
    var isCancelled: Bool {
        state.withLock { $0.isCancelled }
    }

    /// Delivers `level` as the kernel's source would; nothing after ``cancel()``.
    @MainActor func send(_ level: MemoryPressureLevel) {
        guard let deliver = state.withLock({ $0.isCancelled ? nil : $0.deliver }) else { return }
        deliver(level)
    }
}
