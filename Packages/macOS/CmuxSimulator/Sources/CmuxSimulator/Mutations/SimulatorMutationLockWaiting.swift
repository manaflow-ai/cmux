/// An injectable, cancellation-aware pause between advisory lock attempts.
package protocol SimulatorMutationLockWaiting: Sendable {
    /// Suspends before the next nonblocking lock attempt.
    func wait() async throws
}
