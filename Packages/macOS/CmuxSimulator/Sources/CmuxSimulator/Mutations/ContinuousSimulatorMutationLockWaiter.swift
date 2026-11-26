/// Production backoff for contended cross-process mutation locks.
package struct ContinuousSimulatorMutationLockWaiter: SimulatorMutationLockWaiting {
    private let clock = ContinuousClock()

    /// Creates the production lock waiter.
    package init() {}

    package func wait() async throws {
        try await clock.sleep(for: .milliseconds(10))
    }
}
