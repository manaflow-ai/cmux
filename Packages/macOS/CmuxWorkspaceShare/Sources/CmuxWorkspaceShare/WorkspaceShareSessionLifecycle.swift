import Foundation

/// Owns the deterministic connection and reconnect state machine for a share session.
public actor WorkspaceShareSessionLifecycle {
    /// A connection state emitted through ``states()``.
    public enum State: Equatable, Sendable {
        /// The lifecycle has not started.
        case idle

        /// A connection attempt is in progress.
        case connecting(attempt: Int)

        /// The socket is open.
        case connected

        /// A bounded reconnect delay is in progress.
        case reconnecting(attempt: Int, delay: Duration)

        /// The lifecycle is permanently stopped.
        case stopped
    }

    /// A normalized failure used by ``WorkspaceShareRetryPolicy``.
    public enum Failure: Equatable, Sendable {
        /// A transient network or transport error.
        case transport

        /// An HTTP response with an optional parsed `Retry-After` duration.
        case http(statusCode: Int, retryAfter: Duration?)

        /// A WebSocket close frame with its bounded UTF-8 reason, when valid.
        case webSocketClosed(code: Int, reason: String?)

        /// The connection endpoint could not be constructed.
        case invalidEndpoint

        /// The owning session cancelled the connection.
        case cancelled
    }

    /// The current connection state.
    public private(set) var state: State = .idle

    private let retryPolicy: WorkspaceShareRetryPolicy
    private let clockSleep: @Sendable (Duration) async throws -> Void
    private let randomUnitInterval: @Sendable () -> Double
    private var reconnectTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<State>.Continuation] = [:]
    private var consecutiveFailureCount = 0

    /// Creates a lifecycle with injected timing and randomness.
    ///
    /// - Parameters:
    ///   - retryPolicy: Policy used to classify failures and calculate delays.
    ///   - clockSleep: Cancellable sleep operation. The default uses ``ContinuousClock``.
    ///   - randomUnitInterval: Random source in `0...1`, injected for deterministic tests.
    public init(
        retryPolicy: WorkspaceShareRetryPolicy = WorkspaceShareRetryPolicy(),
        clockSleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            // This is the intended bounded reconnect delay, not polling.
            try await ContinuousClock().sleep(for: duration)
        },
        randomUnitInterval: @escaping @Sendable () -> Double = {
            Double.random(in: 0...1)
        }
    ) {
        self.retryPolicy = retryPolicy
        self.clockSleep = clockSleep
        self.randomUnitInterval = randomUnitInterval
    }

    /// Returns a stream that immediately yields the current state.
    ///
    /// The stream finishes permanently after ``stop()``.
    ///
    /// - Returns: State changes for this lifecycle.
    public func states() -> AsyncStream<State> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(state)
            if state == .stopped {
                continuation.finish()
                return
            }
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeContinuation(id: id)
                }
            }
        }
    }

    /// Starts the first connection attempt.
    public func start() {
        guard state == .idle else { return }
        transition(to: .connecting(attempt: 0))
    }

    /// Records a successful socket open without resetting retry backoff.
    public func connectionOpened() async {
        guard state != .stopped else { return }
        let pendingReconnect = reconnectTask
        reconnectTask = nil
        pendingReconnect?.cancel()
        await pendingReconnect?.value
        guard state != .stopped else { return }
        transition(to: .connected)
    }

    /// Resets escalation only after a valid session snapshot enters host state.
    public func sessionSynchronized() {
        guard state != .stopped else { return }
        consecutiveFailureCount = 0
    }

    /// Records a failed connection and either stops or schedules a reconnect.
    ///
    /// - Parameter failure: Normalized connection failure.
    public func connectionFailed(_ failure: Failure) async {
        guard state != .stopped else { return }
        let pendingReconnect = reconnectTask
        reconnectTask = nil
        pendingReconnect?.cancel()
        await pendingReconnect?.value
        guard state != .stopped else { return }

        let failedAttempt = consecutiveFailureCount
        let nextAttempt = failedAttempt + 1

        switch retryPolicy.decision(
            for: failure,
            attempt: failedAttempt,
            randomUnitInterval: randomUnitInterval()
        ) {
        case .stop:
            await stop()
        case .retry(let delay):
            consecutiveFailureCount = nextAttempt
            transition(to: .reconnecting(attempt: nextAttempt, delay: delay))
            let sleep = clockSleep
            reconnectTask = Task { [weak self] in
                do {
                    try await sleep(delay)
                    guard !Task.isCancelled else { return }
                    await self?.reconnectDelayElapsed(attempt: nextAttempt)
                } catch {
                    return
                }
            }
        }
    }

    /// Cancels pending work, emits `.stopped`, and permanently finishes streams.
    public func stop() async {
        guard state != .stopped else { return }
        let pendingReconnect = reconnectTask
        reconnectTask = nil
        pendingReconnect?.cancel()
        await pendingReconnect?.value
        guard state != .stopped else { return }
        state = .stopped
        for continuation in continuations.values {
            continuation.yield(.stopped)
            continuation.finish()
        }
        continuations.removeAll()
    }

    private func transition(to nextState: State) {
        guard state != nextState else { return }
        state = nextState
        for continuation in continuations.values {
            continuation.yield(nextState)
        }
    }

    private func reconnectDelayElapsed(attempt: Int) {
        guard case .reconnecting(let currentAttempt, _) = state,
              currentAttempt == attempt else {
            return
        }
        reconnectTask = nil
        transition(to: .connecting(attempt: attempt))
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    deinit {
        reconnectTask?.cancel()
        for continuation in continuations.values {
            continuation.finish()
        }
    }
}
