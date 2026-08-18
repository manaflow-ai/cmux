import Foundation

/// Awaitable endpoint-activation barrier. Dial paths await `active` instead of
/// observing an "endpoint unavailable" error — the recorded launch pathology
/// was 286 dial failures from dials racing endpoint activation, median
/// launch-to-ready 12.7s with p90 105s.
///
/// The barrier is generation-scoped: recreating the endpoint (health watchdog,
/// background teardown) advances the runtime generation and re-arms the
/// barrier, so a waiter never observes a stale activation.
public actor PeerEndpointReadiness {
    public enum State: Sendable, Equatable {
        case inactive
        case activating
        case active(PeerTransportGeneration)
        case failed(reason: String)
    }

    public struct TimedOut: Error, Sendable {}
    public struct Failed: Error, Sendable {
        public let reason: String
    }

    private var state: State = .inactive
    private var waiters: [UUID: CheckedContinuation<PeerTransportGeneration, any Error>] = [:]

    public init() {}

    public var current: State {
        state
    }

    public func noteActivating() {
        state = .activating
    }

    /// Endpoint became active for `generation`. Resumes every waiter.
    public func noteActive(generation: PeerTransportGeneration) {
        state = .active(generation)
        let resumed = waiters
        waiters.removeAll()
        for (_, continuation) in resumed {
            continuation.resume(returning: generation)
        }
    }

    /// Terminal activation failure. Waiters fail instead of hanging; the
    /// level-triggered rebuilder owns the retry.
    public func noteFailed(reason: String) {
        state = .failed(reason: reason)
        let resumed = waiters
        waiters.removeAll()
        for (_, continuation) in resumed {
            continuation.resume(throwing: Failed(reason: reason))
        }
    }

    /// Endpoint torn down (background, recreate in flight). New waiters park.
    public func noteInactive() {
        state = .inactive
    }

    /// Await an active endpoint, returning its runtime generation. Throws
    /// `TimedOut` after `timeout`, `Failed` when activation reports terminal
    /// failure, `CancellationError` on task cancellation.
    public func awaitActive(
        timeout: Duration,
        clock: ContinuousClock = ContinuousClock()
    ) async throws -> PeerTransportGeneration {
        if case .active(let generation) = state {
            return generation
        }
        if case .failed(let reason) = state {
            throw Failed(reason: reason)
        }
        let id = UUID()
        return try await withThrowingTaskGroup(of: PeerTransportGeneration.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        Task { await self.register(id: id, continuation: continuation) }
                    }
                } onCancel: {
                    Task { await self.cancelWaiter(id: id) }
                }
            }
            group.addTask {
                try await clock.sleep(for: timeout)
                throw TimedOut()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw TimedOut()
            }
            return first
        }
    }

    private func register(
        id: UUID,
        continuation: CheckedContinuation<PeerTransportGeneration, any Error>
    ) {
        // State may have advanced between the caller's check and registration.
        switch state {
        case .active(let generation):
            continuation.resume(returning: generation)
        case .failed(let reason):
            continuation.resume(throwing: Failed(reason: reason))
        case .inactive, .activating:
            waiters[id] = continuation
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
    }
}
