import Foundation

/// Sole dial authority: automatic triggers join work; explicit intent replaces it.
/// Transport failures retry with capped backoff, reset on admission. Denials,
/// supersession, and locally requested closes park automatic recovery.
public actor ReconnectOwner {
    /// One cancellable substrate-plus-admission attempt, transferring its connection on success.
    public typealias ConnectOnce = @Sendable () async throws -> ConnectAttemptResult

    /// ours took over, or the user asked for the close.
    private static let terminalCloseCodes: Set<String> = [
        CloseReason.superseded.code,
        CloseReason.userRequested.code,
        CloseReason.modeSwitched.code,
    ]

    private let connectOnce: ConnectOnce
    private let config: Config
    /// Injected, cancellable sleeper for genuine backoff delays.
    private let sleep: @Sendable (Duration) async throws -> Void
    private var machine = SessionStateMachine()
    private var connection: (any PeerConnection)?
    private var dialTask: Task<Void, Never>?
    /// Owned control readers, cancelled during shutdown even when half-open lanes never EOF.
    private var watchTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var backoff: Duration
    private var stateContinuations: [Int: AsyncStream<SessionState>.Continuation] = [:]
    private var continuationCounter = 0
    /// Observability (8.2): how often the owner actually dialed, admitted.
    public private(set) var dialsStarted = 0
    /// Number of successful admissions accepted by this owner.
    public private(set) var admissions = 0

    /// Sole delivery path for post-admission control frames; a second lane reader would steal them.
    private let onControlFrame: (@Sendable (Frame) async -> Void)?
    private let frameTypePolicy = FrameTypePolicy()

    /// Creates an idle owner; callers supply endpoint readiness and dial intent separately.
    /// - Parameters:
    ///   - config: Retry bounds; defaults to 400 milliseconds through 30 seconds.
    ///   - connectOnce: Cancellable attempt returning a connection and admission verdict.
    ///   - onControlFrame: Optional post-admission consumer; never read the control lane separately.
    ///   - sleep: Cancellable backoff sleeper; defaults to a continuous clock.
    public init(
        config: Config = Config(),
        connectOnce: @escaping ConnectOnce,
        onControlFrame: (@Sendable (Frame) async -> Void)? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { delay in
            try await ContinuousClock().sleep(for: delay)
        }
    ) {
        self.connectOnce = connectOnce
        self.config = config
        self.sleep = sleep
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

    /// Authoritative session state from the owned state machine.
    public var state: SessionState { machine.state }
    /// Connection owned by this generation, or nil before admission and after shutdown.
    public var currentConnection: (any PeerConnection)? { connection }

    /// Bounded recent transition history, attributing every exit from ready to an event.
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

    /// Updates readiness and may release the deferred dial intent.
    /// - Parameter ready: Whether the endpoint permits new dials.
    public func endpointReady(_ ready: Bool) async {
        await apply(machine.handle(.endpointReadyChanged(ready)))
    }

    /// Applies caller intent through the single state-machine mutation path.
    /// - Parameter intent: Automatic joining or explicit replacement intent.
    public func trigger(_ intent: DialIntent) async {
        await apply(machine.handle(.dialRequested(intent)))
    }

    /// Terminally stops this owner; recovery requires a new owner instance.
    /// - Parameter reason: Attributed close cause; defaults to an explicit user stop.
    public func stop(reason: CloseReason = .userRequested) async {
        await apply(machine.handle(.closeRequested(reason)))
    }

    private func removeContinuation(_ id: Int) {
        stateContinuations[id] = nil
    }

    private func publish() {
        for continuation in stateContinuations.values {
            continuation.yield(machine.state)
        }
    }

    private func apply(_ effects: [SessionEffect]) async {
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
                await current?.closeAll(
                    reason: ConnectionTermination(code: reason.code))
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
                await apply(machine.handle(.dialSucceeded(attempt)))
                guard machine.state == .ready else {
                    // The machine rejected the success (defense in depth: the
                    // attempt guard above makes this unreachable). Never keep
                    // a connection the machine never accepted.
                    if connection === conn { connection = nil }
                    await conn.closeAll(
                        reason: ConnectionTermination(code: CloseReason.explicitRedial.code))
                    return
                }
                watch(conn, generation: ConnectionGeneration(raw: attempt.raw))
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
                await apply(machine.handle(.dialFailed(attempt, code: code.rawValue)))
                // Terminal: park in closed(code). Retrying a denial takes a
                // NEW owner (built once the grant situation changed); this
                // one never dials again, on any trigger.
                await apply(
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
            await apply(machine.handle(.dialFailed(attempt, code: "\(error)")))
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
        let sleep = self.sleep
        dialTask = Task {
            try? await sleep(delay)
            guard !Task.isCancelled else { return }
            await self.trigger(.automatic(trigger: "backoff"))
        }
    }


    /// Owns the control lane (lanes are single-consumer) and converts the
    /// connection's end into machine input + the auto-recovery decision.
    /// Frames are surfaced to `onControlFrame` on the way through, never
    /// silently dropped (8.1).
    private func watch(_ conn: any PeerConnection, generation: ConnectionGeneration) {
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
                switch frameTypePolicy.classify(frame.type) {
                case .known, .ignorableUnknown:
                    break
                case .fatalUnknown:
                    if TransportDebugLog.enabled {
                        TransportDebugLog.core.error(
                            """
                            owner \(TransportDebugLog.id(self), privacy: .public) ctl unknown \
                            mandatory frame; closing conn=\(TransportDebugLog.id(conn), privacy: .public) \
                            type=\(frame.type, privacy: .public)
                            """)
                    }
                    await conn.closeAll(
                        reason: ConnectionTermination(code: DenialCode.protocolMismatch.rawValue))
                    break
                }
                if frameTypePolicy.classify(frame.type) == .fatalUnknown { break }
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
            await self.watchEnded(conn, generation: generation)
        }
    }

    /// The watch loop's single exit: drop the stored task, then run the
    /// connection-ended bookkeeping (which ignores stale connections itself).
    private func watchEnded(
        _ conn: any PeerConnection, generation: ConnectionGeneration
    ) async {
        watchTasks.removeValue(forKey: ObjectIdentifier(conn))
        await connectionEnded(conn, generation: generation)
    }

    private func connectionEnded(
        _ conn: any PeerConnection, generation: ConnectionGeneration
    ) async {
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
        let termination = await conn.terminationAfterLaneEOF()
        // `termination()` suspends. An explicit redial or shutdown may have
        // replaced/cleared the connection while the old watcher was waiting;
        // never let that stale watcher apply a remote-close transition to the
        // replacement owner state.
        guard connection === conn else {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.notice(
                    "owner \(TransportDebugLog.id(self), privacy: .public) connection end became stale while awaiting termination conn=\(TransportDebugLog.id(conn), privacy: .public)")
            }
            return
        }
        connection = nil
        let code = termination?.code ?? "connection-lost"
        // Local deliberate closes are preserved as exact codes by the
        // connection owner. A transport diagnostic with no application-close
        // shape is an ordinary loss and redials through capped backoff; an
        // ambiguous peer application close is held down fail-closed so a
        // changed FFI rendering cannot resurrect a superseded session.
        let ambiguousClose = termination?.authority == .ambiguous
        let willAutoRedial = !ambiguousClose
            && !Self.terminalCloseCodes.contains(code)
            && DenialCode(rawValue: code) == nil
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
        await apply(machine.handle(
            .remoteClosed(generation, CloseReason(origin: .remote, code: code))))
        if willAutoRedial {
            // A peer can admit and then immediately close (for example when
            // the bridge loses its current application owner). Route that
            // path through the same capped backoff as transport failures;
            // triggering an automatic dial inline would create an admit/close
            // tight loop with no scheduling boundary.
            scheduleRedial()
        }
    }
}
