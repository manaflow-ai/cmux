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
public struct CloudHubConnector: Sendable {
    public var timeout: Duration = .seconds(15)
    /// A cancellable head start for the preferred family, driven by the injected clock.
    public var fallbackDelay: Duration = .milliseconds(250)
    /// How often a still-unanswered address gets another, independent attempt.
    /// Each address keeps its own timer from its first attempt.
    public var redialInterval: Duration = .milliseconds(50)
    /// Redials per address after its first attempt. The fresh-machine window is well under a
    /// second; after 3 s the in-flight attempts ride normal retransmits, so a
    /// blackholed family never holds more than this many sockets per address.
    public var maxRedials: Int = 60
    public var clock: any Clock<Duration> = ContinuousClock()

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    public func connect(
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
    /// `fallbackDelay`) and gives each started candidate a new attempt every
    /// `redialInterval`, up to `maxRedials` attempts, until the first success.
    /// Every other in-flight or later success is passed to `discard`. Throws the
    /// last failure (or a timeout) when nothing succeeds within `timeout`.
    ///
    /// Redials serve addresses that have not answered. A candidate whose last
    /// attempt failed outright (a SOCKS refusal) is not redialed while another
    /// candidate is still waiting for its head start, or has had an attempt in
    /// flight for less than `fallbackDelay`: the refusal already answered, and
    /// redialing it would dial the failed family on every connection of a
    /// burst. A family silent for longer than that may be blackholed, so the
    /// refused one is redialed again, which covers a new machine whose listener
    /// is not open yet while its other family never answers. Once every
    /// candidate has failed, all of them are redialed. A skipped tick does not
    /// count against `maxRedials`, so waiting never spends a refused family's
    /// redials. Each candidate keeps its own redial timer, so a redial never
    /// starts a fallback before its `fallbackDelay` ends.
    public static func hedged<Value: Sendable>(
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
            var started = Array(repeating: false, count: candidates)
            var inFlight = Array(repeating: 0, count: candidates)
            var failed = Array(repeating: false, count: candidates)
            // Redial attempts launched, capped by `maxRedials`.
            var redials = Array(repeating: 0, count: candidates)
            // Redial ticks elapsed since the candidate started, launched or skipped.
            var ticks = Array(repeating: 0, count: candidates)
            var expired = false
            var lastError: any Error = CloudPortForwardRelay.RelayError.handshakeTimedOut(timeout)
            var winner: Value?

            func scheduleRedial(_ index: Int) {
                guard redials[index] < maxRedials else { return }
                group.addTask {
                    try? await clock.sleep(for: redialInterval)
                    return .redial(index)
                }
            }
            func launch(_ index: Int) {
                started[index] = true
                inFlight[index] += 1
                failed[index] = false
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        return .success(index, try await attempt(index))
                    } catch {
                        return .failure(index, error)
                    }
                }
            }
            func anotherCandidateIsPending(besides index: Int) -> Bool {
                (0..<candidates).contains { other in
                    guard other != index else { return false }
                    guard started[other] else { return true }
                    // Redial ticks measure how long the other family has gone
                    // unanswered; past its head start it may be blackholed.
                    return inFlight[other] > 0 && !failed[other] && redialInterval * ticks[other] < fallbackDelay
                }
            }

            for index in 0..<candidates {
                if index == 0 || fallbackDelay <= .zero {
                    launch(index)
                    scheduleRedial(index)
                } else {
                    group.addTask {
                        try? await clock.sleep(for: fallbackDelay)
                        return .start(index)
                    }
                }
            }
            group.addTask {
                try? await clock.sleep(for: timeout)
                return .deadline
            }
            while let event = try await group.next() {
                switch event {
                case .success(let index, let value):
                    inFlight[index] -= 1
                    if winner == nil {
                        winner = value
                        group.cancelAll()
                    } else {
                        discard(value)
                    }
                case .failure(let index, let error):
                    inFlight[index] -= 1
                    if !(error is CancellationError) {
                        lastError = error
                        failed[index] = true
                    }
                case .start(let index):
                    guard winner == nil, !expired, !Task.isCancelled else { continue }
                    launch(index)
                    scheduleRedial(index)
                case .redial(let index):
                    guard winner == nil, !expired, !Task.isCancelled else { continue }
                    ticks[index] += 1
                    if !(failed[index] && anotherCandidateIsPending(besides: index)) {
                        redials[index] += 1
                        launch(index)
                    }
                    scheduleRedial(index)
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

    public init(
        timeout: Duration = .seconds(15),
        fallbackDelay: Duration = .milliseconds(250),
        redialInterval: Duration = .milliseconds(50),
        maxRedials: Int = 60,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.timeout = timeout
        self.fallbackDelay = fallbackDelay
        self.redialInterval = redialInterval
        self.maxRedials = maxRedials
        self.clock = clock
    }
}

enum CloudHubHedgeEvent<Value: Sendable>: Sendable {
    case success(Int, Value)
    case failure(Int, any Error)
    case start(Int)
    case redial(Int)
    case deadline
}
