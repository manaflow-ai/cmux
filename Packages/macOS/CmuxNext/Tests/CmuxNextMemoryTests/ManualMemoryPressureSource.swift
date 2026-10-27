import CmuxNextCompat

/// A memory pressure source the test drives: ``send(_:)`` sets ``currentLevel`` and delivers the
/// level as the kernel's source would (on the main actor, at once), until the
/// ``MemoryPressureEvents`` holding it cancels it. It delivers a repeated level too, so a test sees
/// what the coordinator does with one.
nonisolated final class ManualMemoryPressureSource: MemoryPressureSource {
    private nonisolated struct State {
        var deliver: (@MainActor @Sendable (MemoryPressureLevel) -> Void)?
        var level: MemoryPressureLevel
        var isCancelled = false
    }

    // The events start and cancel the source on whichever thread runs their init and deinit; a test sends on main.
    private let state: Mutex<State>

    /// Makes a source whose level is `initial` before the first ``send(_:)``.
    init(initial: MemoryPressureLevel = .normal) {
        state = Mutex(State(level: initial))
    }

    func start(delivering deliver: @escaping @MainActor @Sendable (MemoryPressureLevel) -> Void) {
        state.withLock { $0.deliver = deliver }
    }

    func cancel() {
        state.withLock { $0.isCancelled = true }
    }

    var currentLevel: MemoryPressureLevel {
        state.withLock { $0.level }
    }

    /// Sets ``currentLevel`` to `level` and delivers it; nothing after ``cancel()``.
    @MainActor func send(_ level: MemoryPressureLevel) {
        let deliver: (@MainActor @Sendable (MemoryPressureLevel) -> Void)? = state.withLock { state in
            guard !state.isCancelled else { return nil }
            state.level = level
            return state.deliver
        }
        deliver?(level)
    }
}
