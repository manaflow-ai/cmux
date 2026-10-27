import CmuxNextCompat

/// A memory pressure source the test drives: ``send(_:)`` delivers a level as the kernel's source
/// would (on the main actor, at once), until the ``MemoryPressureEvents`` holding it cancels it.
nonisolated final class ManualMemoryPressureSource: MemoryPressureSource {
    private nonisolated struct State {
        var deliver: (@MainActor @Sendable (MemoryPressureLevel) -> Void)?
        var level = MemoryPressureLevel.normal
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

    /// The level last sent; normal before the first.
    var currentLevel: MemoryPressureLevel {
        state.withLock { $0.level }
    }

    /// Delivers `level` as the kernel's source would, after setting ``currentLevel``; nothing after ``cancel()``.
    @MainActor func send(_ level: MemoryPressureLevel) {
        let deliver: (@MainActor @Sendable (MemoryPressureLevel) -> Void)? = state.withLock { state in
            guard !state.isCancelled else { return nil }
            state.level = level
            return state.deliver
        }
        deliver?(level)
    }
}
