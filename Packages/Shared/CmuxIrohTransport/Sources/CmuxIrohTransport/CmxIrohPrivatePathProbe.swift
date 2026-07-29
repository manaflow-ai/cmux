import CMUXMobileCore
import Foundation

/// Runs one bounded private-path dial through an injected transport seam.
struct CmxIrohPrivatePathProbe: Sendable {
    typealias Dial = @Sendable () async throws -> Void
    typealias Now = @Sendable () -> Date
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private enum Observation: Sendable {
        case reachable
        case failed(CmxIrohPrivatePathProbeFailure)
        case timedOut
    }

    private let dial: Dial
    private let now: Now
    private let sleep: Sleep

    /// Creates a probe with injectable dial, clock, and deadline behavior.
    init(
        dial: @escaping Dial,
        now: @escaping Now = { Date() },
        sleep: @escaping Sleep = { duration in
            // This is the probe's real deadline, not polling or settle time.
            try await ContinuousClock().sleep(for: duration)
        }
    ) {
        self.dial = dial
        self.now = now
        self.sleep = sleep
    }

    /// Resolves and dials one exact address with a deadline no longer than five seconds.
    func run(timeout: Duration = .seconds(5)) async -> CmxIrohPrivatePathProbeResult {
        let boundedTimeout = min(max(timeout, .milliseconds(1)), .seconds(5))
        let startedAt = now()
        let observation = await withTaskGroup(of: Observation.self) { group in
            group.addTask { [dial] in
                do {
                    try await dial()
                    return .reachable
                } catch {
                    return .failed(Self.classify(error))
                }
            }
            group.addTask { [sleep] in
                do {
                    try await sleep(boundedTimeout)
                } catch {
                    return .timedOut
                }
                return .timedOut
            }
            let first = await group.next() ?? .failed(.unavailable)
            group.cancelAll()
            return first
        }

        switch observation {
        case .reachable:
            let milliseconds = max(
                0,
                Int((now().timeIntervalSince(startedAt) * 1_000).rounded())
            )
            return .reachable(latencyMilliseconds: milliseconds)
        case let .failed(failure):
            return .unreachable(failure)
        case .timedOut:
            return .unreachable(.timedOut)
        }
    }

    /// One bounded probe phase's outcome: the value or a classified failure.
    enum PhaseOutcome<T: Sendable>: Sendable {
        case success(T)
        case failure(CmxIrohPrivatePathProbeFailure)
    }

    /// Runs one probe phase under a hard deadline, mapping errors through the
    /// probe failure taxonomy.
    ///
    /// Used for the broker-resolution phase, whose expiry reports
    /// ``CmxIrohPrivatePathProbeFailure/unavailable`` rather than
    /// ``CmxIrohPrivatePathProbeFailure/timedOut``: an expired account lookup
    /// says nothing about the probed address, while a dial timeout does.
    ///
    /// - Parameters:
    ///   - timeout: The phase deadline, clamped to 1ms...10s.
    ///   - sleep: The deadline clock, injectable for deterministic tests.
    ///   - operation: The bounded phase work.
    /// - Returns: The operation's value, or a classified failure.
    static func bounded<T: Sendable>(
        timeout: Duration,
        sleep: @escaping Sleep = { duration in
            try await ContinuousClock().sleep(for: duration)
        },
        operation: @escaping @Sendable () async throws -> T
    ) async -> PhaseOutcome<T> {
        let boundedTimeout = min(max(timeout, .milliseconds(1)), .seconds(10))
        return await withTaskGroup(of: PhaseOutcome<T>.self) { group in
            group.addTask {
                do {
                    return .success(try await operation())
                } catch {
                    return .failure(Self.classify(error))
                }
            }
            group.addTask {
                try? await sleep(boundedTimeout)
                return .failure(.unavailable)
            }
            let first = await group.next() ?? .failure(.unavailable)
            group.cancelAll()
            return first
        }
    }

    static func classify(_ error: any Error) -> CmxIrohPrivatePathProbeFailure {
        if let probeError = error as? CmxIrohPrivatePathProbeDialError {
            switch probeError {
            case .stalePort:
                return .stalePort
            case .wrongPeer:
                return .wrongPeer
            case .pathMismatch:
                return .pathMismatch
            }
        }
        switch DiagnosticFailureKind.classify(error) {
        case .identityMismatch:
            return .wrongPeer
        case .timedOut, .transportIdleTimedOut:
            return .timedOut
        case .connectionRefused, .connectionClosed:
            return .macNotListening
        case .offline, .hostUnreachable, .noRoute, .dnsFailed:
            return .noRoute
        case .unsupportedRoute, .credentialUnavailable, .policyUnavailable,
             .endpointUnavailable, .authorizationFailed, .accountMismatch,
             .admissionDenied, .admissionLeaseExpired, .admissionRevalidationFailed,
             .permissionDenied, .secureChannelFailed, .protocolViolation,
             .superseded, .cancelled, .sendQueueOverflow, .unknown, .none:
            return .unavailable
        }
    }
}
