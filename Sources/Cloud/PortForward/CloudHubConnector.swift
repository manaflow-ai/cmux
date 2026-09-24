import Foundation
import Network

/// Connects to the first working private address through one claimed hub.
/// A family can blackhole independently of the other after a VM joins its VPC.
/// Race actual SOCKS CONNECT handshakes, retaining the winning stream and closing
/// every loser before returning, so terminal and browser callers share the policy.
///
/// Each address is also redialed every `redialInterval` until one handshake
/// succeeds or `timeout` passes. A machine created a moment ago is not
/// reachable until its VPC fabric has seen a frame from it; the SYNs of an
/// attempt started before that are lost, and the hub's TCP retransmit backoff
/// (1 s, then 2 s, ...) left New Machine waiting ~3.7 s, or failing at the 15 s
/// deadline, for a daemon that was reachable ~0.4 s after the create response.
/// A fresh attempt costs one local SOCKS connect, so hedging is cheap.
struct CloudHubConnector: Sendable {
    var timeout: Duration = .seconds(15)
    /// A cancellable head start for the preferred family, driven by the injected clock.
    var fallbackDelay: Duration = .milliseconds(250)
    /// How often a still-unanswered address gets another, independent attempt.
    var redialInterval: Duration = .milliseconds(50)
    /// Redial rounds after the first. The fresh-machine window is well under a
    /// second; after 3 s the in-flight attempts ride normal retransmits, so a
    /// blackholed family never holds more than this many sockets per address.
    var maxRedials: Int = 60
    var clock: any Clock<Duration> = ContinuousClock()

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    func connect(
        endpoint: NWEndpoint,
        target: CloudPortForwardTarget,
        queue: DispatchQueue
    ) async throws -> CloudHubConnection {
        let hosts = target.hosts
        return try await Self.hedged(
            candidates: hosts.count,
            fallbackDelay: fallbackDelay,
            redialInterval: redialInterval,
            maxRedials: maxRedials,
            timeout: timeout,
            clock: clock,
            attempt: { index in
                let candidate = CloudHubConnection(connection: NWConnection(to: endpoint, using: .tcp), host: hosts[index])
                do {
                    try await handshake(candidate.connection, host: candidate.host, port: target.port, queue: queue)
                    return candidate
                } catch {
                    candidate.connection.cancel()
                    throw error
                }
            },
            discard: { $0.connection.cancel() }
        )
    }

    /// Runs `attempt(candidate)` for every candidate (each later one delayed by
    /// `fallbackDelay`) and starts a new attempt for every candidate each
    /// `redialInterval`, until the first success. Every other in-flight or later
    /// success is passed to `discard`. Throws the last failure (or a timeout)
    /// when nothing succeeds within `timeout`.
    static func hedged<Value: Sendable>(
        candidates: Int,
        fallbackDelay: Duration,
        redialInterval: Duration,
        maxRedials: Int,
        timeout: Duration,
        clock: any Clock<Duration>,
        attempt: @escaping @Sendable (Int) async throws -> Value,
        discard: @escaping @Sendable (Value) -> Void
    ) async throws -> Value {
        guard candidates > 0 else { throw CancellationError() }
        return try await withThrowingTaskGroup(of: CloudHubHedgeEvent<Value>.self) { group in
            func launch(round: Int) {
                for index in 0..<candidates {
                    let delay = index > 0 && round == 0 ? fallbackDelay : .zero
                    group.addTask {
                        do {
                            if delay > .zero { try await clock.sleep(for: delay) }
                            try Task.checkCancellation()
                            return .success(try await attempt(index))
                        } catch {
                            return .failure(error)
                        }
                    }
                }
            }
            launch(round: 0)
            group.addTask {
                try? await clock.sleep(for: redialInterval)
                return .tick
            }
            group.addTask {
                try? await clock.sleep(for: timeout)
                return .deadline
            }
            var round = 1
            var expired = false
            var lastError: any Error = CloudPortForwardRelay.RelayError.handshakeTimedOut(timeout)
            var winner: Value?
            while let event = try await group.next() {
                switch event {
                case .success(let value):
                    if winner == nil {
                        winner = value
                        group.cancelAll()
                    } else {
                        discard(value)
                    }
                case .failure(let error):
                    if !(error is CancellationError) { lastError = error }
                case .tick:
                    guard winner == nil, !expired, round <= maxRedials else { continue }
                    launch(round: round)
                    round += 1
                    group.addTask {
                        try? await clock.sleep(for: redialInterval)
                        return .tick
                    }
                case .deadline:
                    expired = true
                    if winner == nil { group.cancelAll() }
                }
            }
            // The group drains every child before returning, so late winners
            // were discarded above and no attempt outlives this call.
            if let winner {
                if Task.isCancelled {
                    discard(winner)
                    throw CancellationError()
                }
                return winner
            }
            try Task.checkCancellation()
            throw lastError
        }
    }

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    private func handshake(_ connection: NWConnection, host: String, port: Int, queue: DispatchQueue) async throws {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await connection.startAndWaitUntilReady(queue: queue)
                    try await CloudPortForwardRelay.connect(connection, to: CloudPortForwardTarget(host: host, port: port))
                }
                group.addTask {
                    // A real handshake deadline; completion cancels this child
                    // and expiry cancels the socket to unblock Network callbacks.
                    try await clock.sleep(for: timeout)
                    connection.cancel()
                    throw CloudPortForwardRelay.RelayError.handshakeTimedOut(timeout)
                }
                defer { group.cancelAll() }
                try await group.next()
            }
        } onCancel: {
            connection.cancel()
        }
    }
}

enum CloudHubHedgeEvent<Value: Sendable>: Sendable {
    case success(Value)
    case failure(any Error)
    case tick
    case deadline
}
