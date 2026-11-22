import Synchronization

/// Runs the first closure handed to it and drops the rest, so a
/// continuation fed by several callbacks (state changes, a deadline) is
/// resumed exactly once.
nonisolated final class AgentPaneResumeOnce: Sendable {
    private let done = Mutex(false)

    func run(_ body: () -> Void) {
        let first = done.withLock { done in
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}
