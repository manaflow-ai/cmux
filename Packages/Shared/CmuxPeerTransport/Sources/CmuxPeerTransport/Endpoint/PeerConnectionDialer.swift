public import CmuxPeerTransportCore
internal import Foundation
internal import IrohLib

/// The single outbound dial path. Awaits the endpoint activation barrier
/// (never observes "endpoint unavailable"), fences every continuation on the
/// runtime generation, and maps failures into `PeerDialFailure`
/// classifications. `CancellationError` is NEVER converted into a dial
/// failure.
public struct PeerConnectionDialer: Sendable {
    private let manager: PeerEndpointManager
    private let alpn: String
    private let clock: ContinuousClock

    public init(
        manager: PeerEndpointManager,
        alpn: String = PeerTransportALPN.mobileV2,
        clock: ContinuousClock = ContinuousClock()
    ) {
        self.manager = manager
        self.alpn = alpn
        self.clock = clock
    }

    /// Dials `endpointID` (lowercase hex of the 32-byte key; upstream string
    /// forms also parse) using the given hints.
    ///
    /// - Parameters:
    ///   - relayHints: Relay URLs where the peer may be reachable. Upstream
    ///     `EndpointAddr` carries one home relay, so the first hint is used.
    ///   - directHints: `ip:port` candidates for the peer.
    ///   - generation: The caller's captured runtime generation. When set,
    ///     the dial fails `.transient` if activation has moved on (a recreate
    ///     happened); when nil, the generation published by the activation
    ///     barrier is adopted.
    ///   - timeout: Bound on the connect attempt itself. The FFI call cannot
    ///     be interrupted, so a timed-out attempt is abandoned to clean
    ///     itself up (an orphaned late connection is closed, never leaked).
    ///   - readinessTimeout: Bound on waiting for endpoint activation.
    public func dial(
        endpointID: String,
        relayHints: [String] = [],
        directHints: [String] = [],
        generation: PeerTransportGeneration? = nil,
        timeout: Duration = .seconds(20),
        readinessTimeout: Duration = .seconds(30)
    ) async throws -> PeerQuicConnection {
        let activeGeneration: PeerTransportGeneration
        do {
            activeGeneration = try await manager.readiness.awaitActive(
                timeout: readinessTimeout, clock: clock
            )
        } catch is PeerEndpointReadiness.TimedOut {
            throw PeerDialFailure(
                classification: .transient,
                reason: "endpoint not active within \(readinessTimeout)"
            )
        } catch let failure as PeerEndpointReadiness.Failed {
            throw PeerDialFailure(
                classification: .transient,
                reason: "endpoint activation failed: \(failure.reason)"
            )
        }
        // CancellationError from the barrier propagates untouched.

        if let generation, generation != activeGeneration {
            throw PeerDialFailure(
                classification: .transient,
                reason: "captured \(generation) superseded by \(activeGeneration)"
            )
        }
        let endpoint: Endpoint
        do {
            endpoint = try await manager.liveEndpoint(expecting: activeGeneration)
        } catch {
            throw PeerDialFailure(
                classification: .transient,
                reason: "endpoint unavailable after activation: \(String(describing: error))"
            )
        }
        let target = try Self.parseEndpointID(endpointID)
        let address = EndpointAddr(
            id: target, relayUrl: relayHints.first, addresses: directHints
        )
        let connection = try await connectRacingTimeout(
            endpoint: endpoint, address: address, timeout: timeout
        )
        // Revalidate the captured generation after the connect await: a
        // recreate/deactivate during the handshake makes this connection a
        // zombie on a closed endpoint.
        guard manager.isCurrent(activeGeneration) else {
            try? connection.close(
                errorCode: 0, reason: Data("endpoint superseded during dial".utf8)
            )
            throw PeerDialFailure(
                classification: .transient,
                reason: "endpoint generation advanced during dial"
            )
        }
        return PeerQuicConnection(wrapping: connection)
    }

    // MARK: - Private

    private struct DialTimedOut: Error {}

    /// Races the FFI connect against the timeout. UniFFI async calls do not
    /// observe Swift task cancellation, so the connect runs in an
    /// unstructured task that self-cleans: whichever side loses the race
    /// closes the connection it produced.
    private func connectRacingTimeout(
        endpoint: Endpoint,
        address: EndpointAddr,
        timeout: Duration
    ) async throws -> Connection {
        let slot = PeerOneShotResult<Connection>()
        let alpnData = Data(alpn.utf8)
        let connectTask = Task {
            do {
                let connection = try await endpoint.connect(addr: address, alpn: alpnData)
                if !slot.resolve(.success(connection)) {
                    // Lost to timeout/cancellation: never leak the orphan.
                    try? connection.close(
                        errorCode: 0, reason: Data("dial abandoned".utf8)
                    )
                }
            } catch {
                _ = slot.resolve(.failure(error))
            }
        }
        let timeoutTask = Task { [clock] in
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return // Race already settled and cancelled us.
            }
            _ = slot.resolve(.failure(DialTimedOut()))
        }
        defer {
            timeoutTask.cancel()
            connectTask.cancel()
        }
        do {
            return try await withTaskCancellationHandler {
                try await slot.wait()
            } onCancel: {
                _ = slot.resolve(.failure(CancellationError()))
            }
        } catch is DialTimedOut {
            throw PeerDialFailure(
                classification: .unreachable,
                reason: "dial timed out after \(timeout)"
            )
        } catch let error as IrohError {
            throw Self.classify(error)
        }
        // CancellationError propagates untouched.
    }

    /// Maps FFI connect failures onto the supervisor's failure taxonomy.
    /// Reachability-class kinds arm the retry ladder and mark routes stale;
    /// everything else is transient. Authorization denials never originate
    /// here (admission happens on the control stream, above this layer).
    private static func classify(_ error: IrohError) -> PeerDialFailure {
        let reason = error.message()
        switch error.kind() {
        case .timeout, .connect, .connection:
            return PeerDialFailure(classification: .unreachable, reason: reason)
        case .alpn:
            // Protocol mismatch (old-protocol Mac): one round trip, route stale.
            return PeerDialFailure(
                classification: .unreachable, reason: "alpn mismatch: \(reason)"
            )
        default:
            return PeerDialFailure(classification: .transient, reason: reason)
        }
    }

    /// Accepts the canonical lowercase-hex 64-char form (decoded to bytes so
    /// we never depend on upstream's display format) and falls back to
    /// upstream string parsing. A malformed ID dials nothing and classifies
    /// `.unreachable`.
    private static func parseEndpointID(_ string: String) throws -> EndpointId {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 64, let bytes = PeerHex.decode(trimmed) {
            do {
                return try EndpointId.fromBytes(bytes: bytes)
            } catch let error as IrohError {
                throw PeerDialFailure(
                    classification: .unreachable,
                    reason: "invalid endpoint id: \(error.message())"
                )
            }
        }
        do {
            return try EndpointId.fromString(s: trimmed)
        } catch let error as IrohError {
            throw PeerDialFailure(
                classification: .unreachable,
                reason: "invalid endpoint id: \(error.message())"
            )
        }
    }
}

/// First-writer-wins, single-waiter result slot used to race an
/// uninterruptible FFI call against a timeout or cancellation.
///
/// Sendable invariant: every access to `pending`/`continuation`/`finished`
/// is guarded by `lock`; continuations are resumed exactly once, outside the
/// lock. Exactly one caller may `wait()`.
final class PeerOneShotResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Result<Value, any Error>?
    private var continuation: CheckedContinuation<Value, any Error>?
    private var finished = false

    /// Returns true when this call decided the result; false when a prior
    /// resolve already won (the caller then owns cleanup of its value).
    func resolve(_ result: Result<Value, any Error>) -> Bool {
        lock.lock()
        if finished {
            lock.unlock()
            return false
        }
        finished = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            pending = result
            lock.unlock()
        }
        return true
    }

    func wait() async throws -> Value {
        try await withCheckedThrowingContinuation { newContinuation in
            lock.lock()
            if let pending {
                lock.unlock()
                newContinuation.resume(with: pending)
            } else {
                precondition(continuation == nil, "PeerOneShotResult supports one waiter")
                continuation = newContinuation
                lock.unlock()
            }
        }
    }
}
