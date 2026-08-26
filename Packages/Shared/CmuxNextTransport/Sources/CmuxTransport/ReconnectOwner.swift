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
    /// One ctl watch loop per live connection, keyed by connection identity.
    /// Stored so shutdown can CANCEL them: a half-open connection's ctl lane
    /// never EOFs, and an unstored watch task would keep consuming (and
    /// surfacing) frames forever after stop().
    private var watchTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
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
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                owner \(TransportDebugLog.id(self), privacy: .public) created \
                initialBackoff=\(String(describing: config.initialBackoff), privacy: .public) \
                maxBackoff=\(String(describing: config.maxBackoff), privacy: .public) \
                ctlConsumer=\(self.onControlFrame != nil, privacy: .public)
                """)
        }
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
        // Every apply() call carries exactly one fresh machine transition:
        // log it with its cause (the event) so the persisted log replays the
        // full attributed state history (contract 4.4, 8.1).
        if TransportDebugLog.enabled, let transition = machine.transitions.last {
            TransportDebugLog.core.notice(
                """
                owner \(TransportDebugLog.id(self), privacy: .public) transition \
                \(String(describing: transition.from), privacy: .public) \
                --[\(String(describing: transition.event), privacy: .public)]--> \
                \(String(describing: transition.to), privacy: .public)
                """)
        }
        for effect in effects {
            switch effect {
            case .startDial(let attempt):
                dialsStarted += 1
                if TransportDebugLog.enabled {
                    TransportDebugLog.core.notice(
                        """
                        owner \(TransportDebugLog.id(self), privacy: .public) effect startDial \
                        attempt=\(attempt.raw, privacy: .public) \
                        dialsStarted=\(self.dialsStarted, privacy: .public)
                        """)
                }
                dialTask?.cancel()
                dialTask = Task { await self.runDial(attempt) }
            case .cancelDial(let attempt):
                if TransportDebugLog.enabled {
                    TransportDebugLog.core.notice(
                        """
                        owner \(TransportDebugLog.id(self), privacy: .public) effect cancelDial \
                        attempt=\(attempt.raw, privacy: .public)
                        """)
                }
                dialTask?.cancel()
                dialTask = nil
            case .joinDial(let attempt):
                if TransportDebugLog.enabled {
                    TransportDebugLog.core.notice(
                        """
                        owner \(TransportDebugLog.id(self), privacy: .public) effect joinDial \
                        attempt=\(attempt.raw, privacy: .public)
                        """)
                }
            case .deferDialUntilEndpointReady:
                if TransportDebugLog.enabled {
                    TransportDebugLog.core.notice(
                        """
                        owner \(TransportDebugLog.id(self), privacy: .public) effect \
                        deferDialUntilEndpointReady
                        """)
                }
            case .invalidEventRecorded(let note):
                if TransportDebugLog.enabled {
                    TransportDebugLog.core.notice(
                        """
                        owner \(TransportDebugLog.id(self), privacy: .public) effect \
                        invalidEventRecorded: \(note, privacy: .public)
                        """)
                }
            case .closeConnection(let reason):
                let current = connection
                connection = nil
                // A requested close with no in-flight attempt emits no
                // cancelDial (the machine has nothing to cancel), but a
                // scheduled BACKOFF redial may still be parked in dialTask;
                // left alive it wakes after shutdown and dials a stopped
                // owner back up. Same for the ctl watch loops: on a half-open
                // connection they never EOF, so they must die here, not "when
                // the lane ends".
                dialTask?.cancel()
                dialTask = nil
                for task in watchTasks.values { task.cancel() }
                watchTasks.removeAll()
                if TransportDebugLog.enabled {
                    TransportDebugLog.core.notice(
                        """
                        owner \(TransportDebugLog.id(self), privacy: .public) effect \
                        closeConnection reason=\(reason.code, privacy: .public) \
                        origin=\(reason.origin.rawValue, privacy: .public) \
                        conn=\(current.map { TransportDebugLog.id($0) } ?? "-", privacy: .public)
                        """)
                }
                Task {
                    await current?.closeAll(
                        reason: ConnectionTermination(code: reason.code))
                }
            }
        }
        publish()
    }

    private func runDial(_ attempt: AttemptID) async {
        let dialStart = ContinuousClock.now
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                owner \(TransportDebugLog.id(self), privacy: .public) dial begin \
                attempt=\(attempt.raw, privacy: .public) \
                backoff=\(String(describing: self.backoff), privacy: .public)
                """)
        }
        do {
            let result = try await connectOnce()
            guard !Task.isCancelled else {
                // A replaced attempt may have been ADMITTED before the
                // cancellation landed. Abandoning it would leak a phantom
                // session on the host (cleaned only by supersession later);
                // close it with the honest reason instead. Found by the
                // 2-minute lab soak's launch race (autorun + scene-active).
                if case .admitted(let conn, let sessionID) = result {
                    if TransportDebugLog.enabled {
                        TransportDebugLog.core.notice(
                            """
                            owner \(TransportDebugLog.id(self), privacy: .public) dial \
                            attempt=\(attempt.raw, privacy: .public) admitted-but-replaced \
                            session=\(TransportDebugLog.prefix(sessionID), privacy: .public) \
                            conn=\(TransportDebugLog.id(conn), privacy: .public); closing \
                            reason=\(CloseReason.explicitRedial.code, privacy: .public) \
                            elapsedMs=\(TransportDebugLog.ms(since: dialStart), privacy: .public)
                            """)
                    }
                    await conn.closeAll(
                        reason: ConnectionTermination(code: CloseReason.explicitRedial.code))
                } else if TransportDebugLog.enabled {
                    TransportDebugLog.core.notice(
                        """
                        owner \(TransportDebugLog.id(self), privacy: .public) dial \
                        attempt=\(attempt.raw, privacy: .public) cancelled after \
                        elapsedMs=\(TransportDebugLog.ms(since: dialStart), privacy: .public)
                        """)
                }
                return
            }
            switch result {
            case .admitted(let conn, let sessionID):
                // Validate the attempt is still current BEFORE adopting:
                // cooperative cancellation can land after the isCancelled
                // guard above, and a stale attempt that adopts overwrites
                // (and orphans, never closed) the live connection while the
                // machine rejects its dialSucceeded as stale.
                guard machine.currentAttempt == attempt else {
                    if TransportDebugLog.enabled {
                        TransportDebugLog.core.notice(
                            """
                            owner \(TransportDebugLog.id(self), privacy: .public) dial \
                            attempt=\(attempt.raw, privacy: .public) admitted-but-stale \
                            session=\(TransportDebugLog.prefix(sessionID), privacy: .public) \
                            conn=\(TransportDebugLog.id(conn), privacy: .public); closing \
                            reason=\(CloseReason.explicitRedial.code, privacy: .public) \
                            elapsedMs=\(TransportDebugLog.ms(since: dialStart), privacy: .public)
                            """)
                    }
                    await conn.closeAll(
                        reason: ConnectionTermination(code: CloseReason.explicitRedial.code))
                    return
                }
                connection = conn
                backoff = config.initialBackoff  // success resets backoff (4.6)
                admissions += 1
                if TransportDebugLog.enabled {
                    TransportDebugLog.core.notice(
                        """
                        owner \(TransportDebugLog.id(self), privacy: .public) dial \
                        attempt=\(attempt.raw, privacy: .public) ADMITTED \
                        session=\(TransportDebugLog.prefix(sessionID), privacy: .public) \
                        conn=\(TransportDebugLog.id(conn), privacy: .public) \
                        admissions=\(self.admissions, privacy: .public) \
                        elapsedMs=\(TransportDebugLog.ms(since: dialStart), privacy: .public) \
                        backoffReset=\(String(describing: self.config.initialBackoff), privacy: .public)
                        """)
                }
                apply(machine.handle(.dialSucceeded(attempt)))
                guard machine.state == .ready else {
                    // The machine rejected the success (defense in depth: the
                    // attempt guard above makes this unreachable). Never keep
                    // a connection the machine never accepted.
                    if connection === conn { connection = nil }
                    await conn.closeAll(
                        reason: ConnectionTermination(code: CloseReason.explicitRedial.code))
                    return
                }
                watch(conn)
            case .denied(let code):
                if TransportDebugLog.enabled {
                    TransportDebugLog.core.error(
                        """
                        owner \(TransportDebugLog.id(self), privacy: .public) dial \
                        attempt=\(attempt.raw, privacy: .public) DENIED \
                        code=\(code.rawValue, privacy: .public) \
                        elapsedMs=\(TransportDebugLog.ms(since: dialStart), privacy: .public) \
                        terminal=true (owner never auto-retries a denial)
                        """)
                }
                apply(machine.handle(.dialFailed(attempt, code: code.rawValue)))
                // Terminal: park in closed(code). Retrying a denial takes a
                // NEW owner (built once the grant situation changed); this
                // one never dials again, on any trigger.
                apply(
                    machine.handle(
                        .closeRequested(CloseReason(origin: .remote, code: code.rawValue))))
            }
        } catch {
            guard !Task.isCancelled else {
                if TransportDebugLog.enabled {
                    TransportDebugLog.core.notice(
                        """
                        owner \(TransportDebugLog.id(self), privacy: .public) dial \
                        attempt=\(attempt.raw, privacy: .public) cancelled mid-failure \
                        error=\(String(describing: error), privacy: .public) \
                        elapsedMs=\(TransportDebugLog.ms(since: dialStart), privacy: .public)
                        """)
                }
                return
            }
            if TransportDebugLog.enabled {
                TransportDebugLog.core.error(
                    """
                    owner \(TransportDebugLog.id(self), privacy: .public) dial \
                    attempt=\(attempt.raw, privacy: .public) FAILED \
                    error=\(String(describing: error), privacy: .public) \
                    elapsedMs=\(TransportDebugLog.ms(since: dialStart), privacy: .public); \
                    scheduling backoff redial
                    """)
            }
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
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                owner \(TransportDebugLog.id(self), privacy: .public) backoff redial \
                in=\(String(describing: delay), privacy: .public) \
                nextBackoff=\(String(describing: self.backoff), privacy: .public)
                """)
        }
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
        let key = ObjectIdentifier(conn)
        watchTasks[key]?.cancel()
        watchTasks[key] = Task {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.notice(
                    """
                    owner \(TransportDebugLog.id(self), privacy: .public) watching ctl lane \
                    conn=\(TransportDebugLog.id(conn), privacy: .public)
                    """)
            }
            let control = await conn.lane("ctl")
            for await frame in control.frames {
                // stop() cancels this task, but a frame the iterator already
                // dequeued (or one racing the cancellation's resume) still
                // reaches this point — surface nothing after shutdown.
                if Task.isCancelled { break }
                if TransportDebugLog.enabled {
                    TransportDebugLog.core.notice(
                        """
                        owner \(TransportDebugLog.id(self), privacy: .public) ctl frame \
                        type=\(frame.type, privacy: .public) \
                        conn=\(TransportDebugLog.id(conn), privacy: .public)
                        """)
                }
                await onControlFrame?(frame)
            }
            if TransportDebugLog.enabled {
                TransportDebugLog.core.notice(
                    """
                    owner \(TransportDebugLog.id(self), privacy: .public) ctl lane EOF \
                    conn=\(TransportDebugLog.id(conn), privacy: .public)
                    """)
            }
            await self.watchEnded(conn)
        }
    }

    /// The watch loop's single exit: drop the stored task, then run the
    /// connection-ended bookkeeping (which ignores stale connections itself).
    private func watchEnded(_ conn: any PeerConnection) async {
        watchTasks.removeValue(forKey: ObjectIdentifier(conn))
        await connectionEnded(conn)
    }

    private func connectionEnded(_ conn: any PeerConnection) async {
        guard connection === conn else {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.notice(
                    """
                    owner \(TransportDebugLog.id(self), privacy: .public) stale connection end \
                    ignored conn=\(TransportDebugLog.id(conn), privacy: .public) \
                    current=\(self.connection.map { TransportDebugLog.id($0) } ?? "-", privacy: .public)
                    """)
            }
            return
        }
        connection = nil
        let termination = await conn.termination()
        let code = termination?.code ?? "connection-lost"
        let willAutoRedial =
            !Self.terminalCloseCodes.contains(code) && DenialCode(rawValue: code) == nil
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                owner \(TransportDebugLog.id(self), privacy: .public) connection ended \
                conn=\(TransportDebugLog.id(conn), privacy: .public) \
                code=\(code, privacy: .public) \
                parsedTermination=\(termination != nil, privacy: .public) \
                autoRedial=\(willAutoRedial, privacy: .public)
                """)
        }
        apply(machine.handle(.remoteClosed(CloseReason(origin: .remote, code: code))))
        if willAutoRedial {
            apply(machine.handle(.dialRequested(.automatic(trigger: "connection-ended"))))
        }
    }
}
