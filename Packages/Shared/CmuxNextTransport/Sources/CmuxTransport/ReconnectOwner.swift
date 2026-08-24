import Foundation

/// Outcome of one connect attempt performed by the owner's dialer closure.
public enum ConnectAttemptResult: Sendable {
    case admitted(any PeerConnection, sessionID: String)
    case denied(DenialCode)
}

/// The SINGLE RECONNECT OWNER (contract 4.3, 4.6): the only component in the
/// system that dials. Every trigger (foreground, push, network change, timer,
/// user tap) is an input to it; automatic triggers JOIN the in-flight
/// attempt, explicit intent REPLACES it. Transport failures retry on a
/// capped backoff that resets on success. Denials are TERMINAL for automatic
/// retry purposes: retrying a "no" on a timer is the storm the old stack
/// shipped. Supersession and user-requested closes do not auto-redial;
/// everything else does (that is the auto-recovery the field logs begged for).
public actor ReconnectOwner {
    public typealias ConnectOnce = @Sendable () async throws -> ConnectAttemptResult

    public struct Config: Sendable {
        public var initialBackoff: Duration
        public var maxBackoff: Duration

        public init(
            initialBackoff: Duration = .milliseconds(400),
            maxBackoff: Duration = .seconds(30)
        ) {
            self.initialBackoff = initialBackoff
            self.maxBackoff = maxBackoff
        }
    }

    /// Close codes that must NOT trigger automatic redial: another device of
    /// ours took over, or the user asked for the close.
    private static let terminalCloseCodes: Set<String> = [
        CloseReason.superseded.code,
        CloseReason.userRequested.code,
        CloseReason.modeSwitched.code,
    ]

    private let connectOnce: ConnectOnce
    private let config: Config
    private var machine = SessionStateMachine()
    private var connection: (any PeerConnection)?
    private var dialTask: Task<Void, Never>?
    private var backoff: Duration
    private var stateContinuations: [Int: AsyncStream<SessionState>.Continuation] = [:]
    private var continuationCounter = 0
    /// Observability (8.2): how often the owner actually dialed, admitted.
    public private(set) var dialsStarted = 0
    public private(set) var admissions = 0

    /// Host->client frames observed on the owned ctl lane. The owner is the
    /// SINGLE ctl consumer (lanes are single-consumer); any second reader
    /// races it frame-by-frame and loses — the 08-21 field bug: credential
    /// pushes were drained and DISCARDED by the watch loop while a bolted-on
    /// listener starved. Everything the host says post-admission surfaces
    /// here or nowhere.
    private let onControlFrame: (@Sendable (Frame) async -> Void)?

    public init(
        config: Config = Config(),
        connectOnce: @escaping ConnectOnce,
        onControlFrame: (@Sendable (Frame) async -> Void)? = nil
    ) {
        self.connectOnce = connectOnce
        self.config = config
        self.backoff = config.initialBackoff
        self.onControlFrame = onControlFrame
    }

    public var state: SessionState { machine.state }

    public var currentConnection: (any PeerConnection)? { connection }

    /// The full attributed transition history (contract 4.4, 8.1). The soak
    /// suite's "no sudden reconnects" property is literally: every exit from
    /// ready in this log names a cause the scenario injected.
    public var transitionLog: [SessionTransition] { machine.transitions }

    /// Live state feed for UI; yields the current state immediately.
    public func states() -> AsyncStream<SessionState> {
        AsyncStream { continuation in
            continuationCounter += 1
            let id = continuationCounter
            stateContinuations[id] = continuation
            continuation.yield(machine.state)
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(id) }
            }
        }
    }

    public func endpointReady(_ ready: Bool) {
        apply(machine.handle(.endpointReadyChanged(ready)))
    }

    public func trigger(_ intent: DialIntent) {
        apply(machine.handle(.dialRequested(intent)))
    }

    public func stop(reason: CloseReason = .userRequested) {
        apply(machine.handle(.closeRequested(reason)))
    }

    private func removeContinuation(_ id: Int) {
        stateContinuations[id] = nil
    }

    private func publish() {
        for continuation in stateContinuations.values {
            continuation.yield(machine.state)
        }
    }

    private func apply(_ effects: [SessionEffect]) {
        for effect in effects {
            switch effect {
            case .startDial(let attempt):
                dialsStarted += 1
                dialTask?.cancel()
                dialTask = Task { await self.runDial(attempt) }
            case .cancelDial:
                dialTask?.cancel()
                dialTask = nil
            case .joinDial, .deferDialUntilEndpointReady, .invalidEventRecorded:
                break
            case .closeConnection(let reason):
                let current = connection
                connection = nil
                Task {
                    await current?.closeAll(
                        reason: ConnectionTermination(code: reason.code))
                }
            }
        }
        publish()
    }

    private func runDial(_ attempt: AttemptID) async {
        do {
            let result = try await connectOnce()
            guard !Task.isCancelled else {
                // A replaced attempt may have been ADMITTED before the
                // cancellation landed. Abandoning it would leak a phantom
                // session on the host (cleaned only by supersession later);
                // close it with the honest reason instead. Found by the
                // 2-minute lab soak's launch race (autorun + scene-active).
                if case .admitted(let conn, _) = result {
                    await conn.closeAll(
                        reason: ConnectionTermination(code: CloseReason.explicitRedial.code))
                }
                return
            }
            switch result {
            case .admitted(let conn, _):
                connection = conn
                backoff = config.initialBackoff  // success resets backoff (4.6)
                admissions += 1
                apply(machine.handle(.dialSucceeded(attempt)))
                watch(conn)
            case .denied(let code):
                apply(machine.handle(.dialFailed(attempt, code: code.rawValue)))
                // Terminal: park in closed(code). A later trigger (user tap,
                // foreground after a grant renewal) may try again; the owner
                // itself never schedules a retry against a denial.
                apply(
                    machine.handle(
                        .closeRequested(CloseReason(origin: .remote, code: code.rawValue))))
            }
        } catch {
            guard !Task.isCancelled else { return }
            apply(machine.handle(.dialFailed(attempt, code: "\(error)")))
            scheduleRedial()
        }
    }

    /// Capped, cancellable backoff (an intentional bounded delay through the
    /// clock, not a synchronization substitute: the redial it wakes is an
    /// ordinary automatic trigger that joins whatever else happened since).
    private func scheduleRedial() {
        let delay = backoff
        backoff = min(backoff * 2, config.maxBackoff)
        dialTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self.trigger(.automatic(trigger: "backoff"))
        }
    }

    /// Owns the control lane (lanes are single-consumer) and converts the
    /// connection's end into machine input + the auto-recovery decision.
    /// Frames are surfaced to `onControlFrame` on the way through, never
    /// silently dropped (8.1).
    private func watch(_ conn: any PeerConnection) {
        Task {
            let control = await conn.lane("ctl")
            for await frame in control.frames {
                await onControlFrame?(frame)
            }
            await self.connectionEnded(conn)
        }
    }

    private func connectionEnded(_ conn: any PeerConnection) async {
        guard connection === conn else { return }
        connection = nil
        let termination = await conn.termination()
        let code = termination?.code ?? "connection-lost"
        apply(machine.handle(.remoteClosed(CloseReason(origin: .remote, code: code))))
        if !Self.terminalCloseCodes.contains(code), DenialCode(rawValue: code) == nil {
            apply(machine.handle(.dialRequested(.automatic(trigger: "connection-ended"))))
        }
    }
}
