// One relay WebSocket leg to the account's Durable Object.
//
// Owns: dial + hello, transparent resume with upload resend buffering (pruned
// on relay `ackup`) and download ack emission, app-level keepalive pings,
// read-liveness + sleep (clock-jump) watchdogs, and in-band auth refresh well
// ahead of the relay deadline.
//
// Reliability contract for callers: `send` buffers across suspensions and
// never loses frames while the leg is logically alive; per-destination order
// is preserved end to end (sequenced uploads + a single ordered writer);
// duplicates from resume overlap are dropped internally; `.reset` is the ONLY
// loss signal, after which every E2E session over this leg is dead and the
// leg re-establishes fresh.

public import Foundation

public actor DorLeg {
    public let configuration: DorLegConfiguration

    private enum Phase {
        case idle
        case running
        case stopped
    }

    /// Connection-attempt outcome classification for the run loop.
    private enum LegOutcome: Error {
        /// Transient: redial with resume after backoff.
        case suspend(String)
        /// The relay refused the resume: continuity lost, start fresh now.
        case resumeRefused(String)
        /// No further dialing (auth rejected twice, superseded, capacity).
        case terminal(String)
    }

    private let journal: DorJournal
    private let urlSession: URLSession

    private var phase: Phase = .idle
    private var continuation: AsyncStream<DorLegEvent>.Continuation?
    private var runTask: Task<Void, Never>?

    private var ledger: DorLedger
    private var socket: URLSessionWebSocketTask?
    /// Ordered outbound data-frame writer feed for the CURRENT connection.
    private var outbox: AsyncStream<Data>.Continuation?
    private var currentLegID: UInt32?
    private var resumeKey: String?
    /// A hello completed on the current continuity (controls .suspended).
    private var established = false
    private var notifiedSuspended = false
    private var helloDone = false

    private var lastInbound = ContinuousClock.now
    private var lastPingAt = ContinuousClock.now
    private var lastAuthRefreshAt = ContinuousClock.now
    private var monotonicBase = ContinuousClock.now
    private var consecutiveAuthCloses = 0
    private var consecutiveProtocolCloses = 0

    public init(configuration: DorLegConfiguration) {
        self.configuration = configuration
        self.journal = configuration.journal
        self.ledger = DorLedger(role: configuration.role)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.waitsForConnectivity = false
        sessionConfiguration.timeoutIntervalForRequest = 15
        self.urlSession = URLSession(configuration: sessionConfiguration)
    }

    /// This leg's relay-assigned id (nil until the first hello.ack).
    public var legID: UInt32? {
        currentLegID
    }

    /// Start dialing. Events (including all inbound frames) arrive on the
    /// returned stream; exactly one consumer may iterate it.
    public func start() -> AsyncStream<DorLegEvent> {
        precondition(phase == .idle, "DorLeg.start called twice")
        phase = .running
        let (stream, continuation) = AsyncStream<DorLegEvent>.makeStream(
            bufferingPolicy: .unbounded)
        self.continuation = continuation
        runTask = Task { await self.run() }
        return stream
    }

    /// Send one E2E payload to the peer. Host: `destination` = phone leg id.
    /// Phone: destination is ignored (the relay routes uploads to the Mac).
    public func send(_ payload: Data, to destination: UInt32) async throws {
        guard phase == .running else { throw DorLegError.stopped }
        // Seq assignment and outbox enqueue are one synchronous section, so
        // wire order always equals seq order.
        guard let frame = ledger.recordUpload(payload: payload, destination: destination) else {
            // Resend buffer exhausted: continuity is unprovable from here.
            // Reset the leg (the ONLY loss signal); sessions die with it.
            forceReset(reason: "upload-buffer-overflow")
            return
        }
        if helloDone {
            outbox?.yield(frame.encoded)
        }
    }

    public func stop() async {
        guard phase != .stopped else { return }
        phase = .stopped
        runTask?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        outbox?.finish()
        outbox = nil
        journal.record(component: "leg", event: "stopped", attributes: legAttributes())
        continuation?.yield(.closed(reason: "stopped"))
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Run loop

    private func run() async {
        var backoff: Duration = .milliseconds(200)
        while phase == .running, !Task.isCancelled {
            let attemptStart = ContinuousClock.now
            do {
                try await connectOnce()
                return // only stop() exits cleanly; it already finished the stream
            } catch let outcome as LegOutcome {
                guard phase == .running else { return }
                switch outcome {
                case .resumeRefused(let reason):
                    journal.record(
                        component: "leg", event: "reset",
                        attributes: legAttributes(["reason": reason]))
                    continuation?.yield(.reset(reason: reason))
                    resumeKey = nil
                    currentLegID = nil
                    established = false
                    notifiedSuspended = false
                    ledger.resetForFreshSession()
                    backoff = .milliseconds(200)
                    // Redial immediately: the relay answered, the network is up.
                case .terminal(let reason):
                    journal.record(
                        component: "leg", event: "closed",
                        attributes: legAttributes(["reason": reason]))
                    phase = .stopped
                    continuation?.yield(.closed(reason: reason))
                    continuation?.finish()
                    continuation = nil
                    return
                case .suspend(let reason):
                    if established, !notifiedSuspended {
                        notifiedSuspended = true
                        journal.record(
                            component: "leg", event: "suspended",
                            attributes: legAttributes(["reason": reason]))
                        continuation?.yield(.suspended(reason: reason))
                    } else if !established {
                        journal.record(
                            component: "leg", event: "dial-retry",
                            attributes: legAttributes(["reason": reason]))
                    }
                    // A connection that survived a while earns a fresh ladder.
                    if ContinuousClock.now - attemptStart > .seconds(30) {
                        backoff = .milliseconds(200)
                    }
                    try? await Task.sleep(for: backoff)
                    backoff = min(backoff * 2, .seconds(5))
                }
            } catch {
                return // cancelled
            }
        }
    }

    /// One full connection: dial, hello (resume when possible), then pump
    /// until something breaks. Always throws a `LegOutcome`.
    private func connectOnce() async throws {
        let token: String
        do {
            token = try await configuration.tokenProvider()
        } catch {
            throw LegOutcome.suspend("token-unavailable")
        }
        guard let url = dialURL() else {
            throw LegOutcome.terminal("invalid-relay-url")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let socket = urlSession.webSocketTask(with: request)
        socket.maximumMessageSize = 2 * 1024 * 1024
        self.socket = socket
        helloDone = false
        defer {
            socket.cancel(with: .abnormalClosure, reason: nil)
            if self.socket === socket { self.socket = nil }
            outbox?.finish()
            outbox = nil
            helloDone = false
        }
        socket.resume()

        // ---- hello (the relay replays gap frames BEFORE hello.ack) ----
        let wasResume = resumeKey != nil
        do {
            try await sendControl(
                .hello(
                    device: configuration.selfDeviceID,
                    resume: resumeKey,
                    ack: configuration.role == .phone && wasResume ? ledger.resumeAck : nil,
                    acks: configuration.role == .host && wasResume ? ledger.resumeAcks : nil
                ),
                over: socket
            )
        } catch {
            throw classifyFailure(socket, fallback: "hello-send-failed")
        }
        let ack = try await helloAck(over: socket)
        currentLegID = ack.legID
        resumeKey = ack.resumeKey
        lastInbound = ContinuousClock.now
        lastPingAt = ContinuousClock.now
        lastAuthRefreshAt = ContinuousClock.now
        consecutiveAuthCloses = 0
        consecutiveProtocolCloses = 0
        notifiedSuspended = false

        // Ordered writer feed for this connection, seeded with every frame
        // the relay has not confirmed ring-durable (the relay dedups resends
        // by seq, so overlap is harmless).
        let (frames, outboxContinuation) = AsyncStream<Data>.makeStream(
            bufferingPolicy: .unbounded)
        outbox = outboxContinuation
        for frame in ledger.framesForResend() {
            outboxContinuation.yield(frame.encoded)
        }
        helloDone = true

        if wasResume {
            journal.record(
                component: "leg", event: "resumed",
                attributes: legAttributes([
                    "replayed": String(ack.replayed),
                    "resent": String(ledger.totalBufferedFrames),
                ]))
            continuation?.yield(.resumed(replayedFrames: ack.replayed))
        } else {
            established = true
            journal.record(
                component: "leg", event: "up",
                attributes: legAttributes(["peer_online": String(ack.peerOnline)]))
            continuation?.yield(.up(peerOnline: ack.peerOnline))
        }

        // ---- steady state: reader + writer + ticker; first throw wins ----
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.receiveLoop(socket) }
                group.addTask { try await self.writerLoop(socket, frames: frames) }
                group.addTask { try await self.tickerLoop(socket) }
                defer { group.cancelAll() }
                try await group.next()
            }
            throw LegOutcome.suspend("pump-ended")
        } catch let outcome as LegOutcome {
            throw outcome
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw classifyFailure(socket, fallback: "socket-error")
        }
    }

    /// Receive until hello.ack, processing replayed data frames on the way.
    private func helloAck(
        over socket: URLSessionWebSocketTask
    ) async throws -> (legID: UInt32, resumeKey: String, peerOnline: Bool, replayed: Int) {
        let deadline = ContinuousClock.now + .seconds(15)
        while true {
            guard ContinuousClock.now < deadline else {
                throw LegOutcome.suspend("hello-timeout")
            }
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                throw classifyFailure(socket, fallback: "hello-receive-failed")
            }
            switch message {
            case .data(let data):
                handleDataFrame(data)
            case .string(let text):
                guard let control = try? DorControlFrame.decode(text) else { continue }
                switch control {
                case let .helloAck(legID, resumeKey, _, peerOnline, replayed):
                    return (legID, resumeKey, peerOnline, replayed)
                case let .resumeFailed(reason):
                    throw LegOutcome.resumeRefused(reason)
                case let .error(code, message):
                    journal.record(
                        component: "leg", event: "relay-error",
                        attributes: legAttributes(["code": code, "message": message]))
                default:
                    continue
                }
            @unknown default:
                continue
            }
        }
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask) async throws {
        while true {
            try Task.checkCancellation()
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw classifyFailure(socket, fallback: "receive-failed")
            }
            lastInbound = ContinuousClock.now
            switch message {
            case .data(let data):
                if let source = handleDataFrame(data) {
                    // Coalesced: at most one ack per stream per 16 frames /
                    // 100ms; the 1s ticker flushes stragglers.
                    if case let .ack(seq, leg) = ledger.ackDecision(
                        source: source, now: nowSeconds())
                    {
                        try await sendControl(.ack(seq: seq, leg: leg), over: socket)
                    }
                }
            case .string(let text):
                try await handleControl(text, over: socket)
            @unknown default:
                continue
            }
        }
    }

    private func writerLoop(
        _ socket: URLSessionWebSocketTask,
        frames: AsyncStream<Data>
    ) async throws {
        for await frame in frames {
            try Task.checkCancellation()
            do {
                try await socket.send(.data(frame))
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw classifyFailure(socket, fallback: "send-failed")
            }
        }
        throw CancellationError() // outbox finished: connection is over
    }

    /// 1s cadence: keepalive pings, coalesced-ack flush, read-liveness and
    /// sleep watchdogs, in-band auth refresh.
    private func tickerLoop(_ socket: URLSessionWebSocketTask) async throws {
        var lastContinuous = ContinuousClock.now
        var lastSuspending = SuspendingClock.now
        while true {
            try await Task.sleep(for: .seconds(1))
            let now = ContinuousClock.now

            // Sleep detection: the continuous clock runs while the machine
            // sleeps, the suspending clock does not. Divergence means the
            // process slept — the socket is almost certainly dead; redial now.
            let continuousElapsed = now - lastContinuous
            let suspendingElapsed = SuspendingClock.now - lastSuspending
            lastContinuous = now
            lastSuspending = SuspendingClock.now
            if continuousElapsed - suspendingElapsed
                > .seconds(configuration.clockJumpThreshold)
            {
                throw LegOutcome.suspend("clock-jump")
            }

            if now - lastInbound > .seconds(configuration.readLivenessDeadline) {
                throw LegOutcome.suspend("read-liveness")
            }

            if now - lastPingAt >= .seconds(configuration.keepaliveInterval) {
                lastPingAt = now
                try await sendControl(.ping(ts: monotonicMilliseconds()), over: socket)
            }

            for decision in ledger.flushAcks(now: nowSeconds()) {
                if case let .ack(seq, leg) = decision {
                    try await sendControl(.ack(seq: seq, leg: leg), over: socket)
                }
            }

            if now - lastAuthRefreshAt >= .seconds(configuration.authRefreshInterval) {
                lastAuthRefreshAt = now
                let token: String
                do {
                    token = try await configuration.tokenProvider()
                } catch {
                    // Token source hiccup: journal and retry next interval;
                    // the current deadline still has ≥10 minutes of slack.
                    journal.record(
                        component: "leg", event: "auth-refresh-deferred",
                        attributes: legAttributes(["reason": "token-unavailable"]))
                    continue
                }
                try await sendControl(.authRefresh(token: token), over: socket)
            }
        }
    }

    // MARK: - Inbound handling

    private func handleControl(
        _ text: String, over socket: URLSessionWebSocketTask
    ) async throws {
        let control: DorControlFrame?
        do {
            control = try DorControlFrame.decode(text)
        } catch {
            journal.record(
                component: "leg", event: "malformed-control",
                attributes: legAttributes())
            return
        }
        switch control {
        case let .pong(ts):
            let rtt = max(0, monotonicMilliseconds() - ts)
            journal.record(
                component: "keepalive", event: "pong",
                attributes: legAttributes([
                    "path": "do:relay",
                    "rtt_ms": String(Int(rtt)),
                ]))
        case let .ackUp(seq, leg):
            ledger.handleAckUp(seq: seq, leg: leg)
        case let .authOK(deadline):
            journal.record(
                component: "leg", event: "auth-refreshed",
                attributes: legAttributes([
                    "deadline_in_s": String(Int((deadline / 1000) - Date().timeIntervalSince1970)),
                ]))
        case let .peerOnline(legID, device):
            continuation?.yield(.peerOnline(legID: legID, device: device))
        case let .peerOffline(legID, reason):
            continuation?.yield(.peerOffline(legID: legID, reason: reason))
        case let .resumeFailed(reason):
            throw LegOutcome.resumeRefused(reason)
        case let .error(code, message):
            journal.record(
                component: "leg", event: "relay-error",
                attributes: legAttributes(["code": code, "message": message]))
        case .helloAck, .hello, .ping, .ack, .authRefresh, nil:
            return
        }
    }

    /// Returns the source leg id when the frame was fresh (not a replay).
    @discardableResult
    private func handleDataFrame(_ data: Data) -> UInt32? {
        guard let frame = DorWire.decodeData(data) else {
            journal.record(
                component: "leg", event: "malformed-data",
                attributes: legAttributes())
            return nil
        }
        guard ledger.acceptDownload(source: frame.legID, seq: frame.seq) else {
            return nil // resume-overlap replay
        }
        continuation?.yield(.frame(sourceLegID: frame.legID, payload: frame.payload))
        return frame.legID
    }

    // MARK: - Helpers

    private func forceReset(reason: String) {
        journal.record(
            component: "leg", event: "reset",
            attributes: legAttributes(["reason": reason]))
        continuation?.yield(.reset(reason: reason))
        resumeKey = nil
        currentLegID = nil
        established = false
        ledger.resetForFreshSession()
        // Kill the current socket; the run loop redials fresh.
        socket?.cancel(with: .abnormalClosure, reason: nil)
    }

    private func sendControl(
        _ frame: DorControlFrame, over socket: URLSessionWebSocketTask
    ) async throws {
        let text: String
        do {
            text = try frame.encoded()
        } catch {
            throw LegOutcome.terminal("control-encoding-failed")
        }
        do {
            try await socket.send(.string(text))
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw classifyFailure(socket, fallback: "control-send-failed")
        }
    }

    /// Map a dead socket to a run-loop outcome using the close code the
    /// relay supplied (ObjC-backed enum preserves 4xxx raw values).
    private func classifyFailure(
        _ socket: URLSessionWebSocketTask, fallback: String
    ) -> LegOutcome {
        let code = socket.closeCode.rawValue
        let reason = socket.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? fallback
        switch UInt16(exactly: code) {
        case DorWire.closeUnauthorized:
            consecutiveAuthCloses += 1
            return consecutiveAuthCloses >= 2
                ? .terminal("unauthorized")
                : .suspend("unauthorized-retry")
        case DorWire.closeSuperseded:
            return .terminal("superseded")
        case DorWire.closeCapacity:
            return .terminal("capacity")
        case DorWire.closeProtocolError:
            consecutiveProtocolCloses += 1
            return consecutiveProtocolCloses >= 3
                ? .terminal("protocol-error")
                : .suspend("protocol-error-retry")
        default:
            return .suspend(reason)
        }
    }

    private func dialURL() -> URL? {
        guard var components = URLComponents(
            url: configuration.relayBaseURL, resolvingAgainstBaseURL: false)
        else { return nil }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = configuration.role == .host ? "/v1/dor/host" : "/v1/dor/connect"
        var query = [URLQueryItem(name: "device", value: configuration.selfDeviceID)]
        if configuration.role == .phone {
            query.append(URLQueryItem(name: "mac", value: configuration.macDeviceID))
        }
        components.queryItems = query
        return components.url
    }

    private func legAttributes(_ extra: [String: String] = [:]) -> [String: String] {
        var attributes = extra
        attributes["role"] = configuration.role.rawValue
        attributes["mac"] = configuration.macDeviceID
        if let currentLegID { attributes["leg"] = String(currentLegID) }
        return attributes
    }

    private func monotonicMilliseconds() -> Double {
        let elapsed = monotonicBase.duration(to: .now)
        return Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
    }

    private func nowSeconds() -> TimeInterval {
        monotonicMilliseconds() / 1000
    }
}

public enum DorLegError: Error, Sendable {
    case stopped
}
