import Synchronization

/// Runs the first `resume` body only; later calls are dropped. Guards a
/// continuation that several callbacks may try to finish.
final class ResumeOnce: Sendable {
    private let done = Mutex(false)

    func resume(_ body: () -> Void) {
        let first = done.withLock { done in
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}
