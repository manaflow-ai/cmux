// One relay WebSocket leg (see DotTransportAPI.swift for the contract).
//
// Owns: dial + hello, transparent resume with upload resend buffering
// (pruned on relay `ackup`) and download ack emission, app-level keepalive
// pings, read-liveness + clock-jump watchdogs (chatmux-relay lineage), and
// in-band auth refresh ahead of the relay's verified deadline.
//
// Reliability contract for callers: `send` never fails while the leg is
// logically alive (frames buffer across suspensions and flush on resume);
// ordering per destination is preserved; duplicates are dropped on resume
// overlap; a `.reset` event is the ONLY loss signal.
public import Foundation

public enum DotLegError: Error, Sendable {
    /// The leg was stopped (or terminally closed) before/while sending.
    case stopped
    /// The resend buffer overflowed; continuity is unprovable and the leg
    /// re-established fresh (callers observe `.reset` on the event stream).
    case continuityLost
}

public actor DotLeg {
    public let configuration: DotLegConfiguration

    private enum Phase {
        case idle
        case running
        case stopped
    }

    /// Redial backoff ladder (seconds); resets on every successful hello.ack.
    private static let redialBackoff: [Double] = [0.2, 0.5, 1, 2, 5, 10]
    /// Auth refresh margin before the relay's verified deadline.
    private static let authRefreshMargin: TimeInterval = 120
    /// Relay auth deadlines are capped at 15 minutes per verification.
    private static let authDeadlineCap: TimeInterval = 15 * 60
    /// Send gate: block writers above this much un-acked upload buffer while
    /// the socket is up (the relay's ackup normally prunes within one RTT).
    private static let sendGateBytes = 2 * 1024 * 1024

    private var phase: Phase = .idle
    private var continuation: AsyncStream<DotLegEvent>.Continuation?
    private let session: URLSession

    // Per-socket-generation tasks; a new dial invalidates them all.
    private var socket: URLSessionWebSocketTask?
    private var socketGeneration = 0
    private var receiveTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var authTask: Task<Void, Never>?
    private var establishTimeoutTask: Task<Void, Never>?
    private var redialTask: Task<Void, Never>?

    // Continuity state (survives socket generations, cleared on reset).
    private var ledger: DotLegLedger
    private var resumeKey: String?
    private var epoch: String?
    private var assignedLegID: UInt32?
    private var established = false
    private var everConnected = false
    private var redialAttempt = 0

    // Watchdog baselines.
    private let clock = ContinuousClock()
    private let startedAt: ContinuousClock.Instant
    private var lastInboundAt: ContinuousClock.Instant
    private var wallBaseline = Date()
    private var monoBaseline: ContinuousClock.Instant
    private var pingSentAt: ContinuousClock.Instant?

    // Auth refresh bookkeeping.
    private var authDeadline: Date?
    private var authOKWaiter: CheckedContinuation<Date, any Error>?

    // Writers gated on buffer drain (resumed on ackup / state changes).
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    // Serialized outbound data writer (wire order must equal seq order).
    private var outboundFIFO: [Data] = []
    private var pumpRunning = false
    private var pumpTask: Task<Void, Never>?

    public init(configuration: DotLegConfiguration) {
        self.configuration = configuration
        self.ledger = DotLegLedger(role: configuration.role)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.waitsForConnectivity = false
        self.session = URLSession(configuration: sessionConfiguration)
        let now = ContinuousClock.now
        self.startedAt = now
        self.lastInboundAt = now
        self.monoBaseline = now
    }

    /// Start dialing. Events (including all inbound frames) arrive on the
    /// returned stream; exactly one consumer may iterate it.
    public func start() -> AsyncStream<DotLegEvent> {
        let (stream, continuation) = AsyncStream<DotLegEvent>.makeStream()
        self.continuation = continuation
        guard phase == .idle else {
            continuation.finish()
            return stream
        }
        phase = .running
        journal("dialing", ["trigger": "start"])
        Task { await self.dial() }
        return stream
    }

    /// Send one E2E payload to the peer. Host: `destination` = phone leg id.
    /// Phone: destination is ignored (the relay routes uploads to the host).
    public func send(_ payload: Data, to destination: UInt32) async throws {
        guard phase == .running else { throw DotLegError.stopped }
        // Flow control: above the gate while the socket is up, wait for the
        // relay's ackup to prune the buffer instead of growing toward the
        // hard cap (which would force a reset).
        while phase == .running, established,
            ledger.totalBufferedBytes > Self.sendGateBytes
        {
            await withCheckedContinuation { continuation in
                drainWaiters.append(continuation)
            }
        }
        guard phase == .running else { throw DotLegError.stopped }
        guard let frame = ledger.recordUpload(payload: payload, destination: destination)
        else {
            // Hard cap: continuity is unprovable past this point (the relay
            // ring could not cover the gap either). Reset to a fresh leg.
            await loseContinuity(reason: "upload-buffer-overflow")
            throw DotLegError.continuityLost
        }
        outboundFIFO.append(frame.encoded)
        kickPump()
    }

    /// Single serialized writer: per-destination wire order must equal seq
    /// order, so exactly one task ever writes data frames to the socket. The
    /// FIFO is rebuilt from the ledger on every hello.ack (see there).
    private func kickPump() {
        guard established, !pumpRunning else { return }
        pumpRunning = true
        pumpTask = Task { [weak self] in
            await self?.runPump()
        }
    }

    private func runPump() async {
        var failedSocket: URLSessionWebSocketTask?
        while phase == .running, established, let socket, !outboundFIFO.isEmpty {
            guard socket !== failedSocket else { break }
            let next = outboundFIFO.removeFirst()
            do {
                try await socket.send(.data(next))
            } catch {
                // The receive loop owns failure handling; every un-acked
                // frame stays in the ledger and replays on the next
                // hello.ack's FIFO rebuild.
                failedSocket = socket
                break
            }
        }
        pumpRunning = false
        // A hello.ack may have rebuilt the FIFO while this pump was stuck in
        // a send on the dying socket; restart against the new socket.
        if phase == .running, established, !outboundFIFO.isEmpty,
            socket !== failedSocket
        {
            kickPump()
        }
    }

    /// This leg's relay-assigned id (nil until the first hello.ack).
    public var legID: UInt32? {
        assignedLegID
    }

    public func stop() async {
        guard phase != .stopped else { return }
        phase = .stopped
        cancelGenerationTasks()
        redialTask?.cancel()
        redialTask = nil
        pumpTask?.cancel()
        pumpTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        resumeDrainWaiters()
        failAuthWaiter(DotLegError.stopped)
        journal("stopped")
        continuation?.yield(.closed(reason: "stopped"))
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Dial and establishment

    private func dial() async {
        guard phase == .running else { return }
        socketGeneration += 1
        let generation = socketGeneration
        cancelGenerationTasks()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        established = false

        let token: String
        do {
            token = try await configuration.tokenProvider()
        } catch {
            journal("dial-failed", ["reason": "token: \(error)"])
            scheduleRedial(generation: generation)
            return
        }
        guard phase == .running, generation == socketGeneration else { return }
        guard let url = dialURL() else {
            journal("dial-failed", ["reason": "invalid-relay-url"])
            scheduleRedial(generation: generation)
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 2 * 1024 * 1024
        socket.resume()
        self.socket = socket

        let hello: DotControlFrame = .hello(
            device: configuration.selfDeviceID,
            resume: resumeKey,
            ack: (configuration.role == .phone && resumeKey != nil)
                ? ledger.resumeAck : nil,
            acks: (configuration.role == .host && resumeKey != nil)
                ? ledger.resumeAcks : nil
        )
        do {
            try await socket.send(.string(hello.encoded()))
        } catch {
            guard generation == socketGeneration, phase == .running else { return }
            journal("dial-failed", ["reason": "hello-send: \(error)"])
            scheduleRedial(generation: generation)
            return
        }
        guard generation == socketGeneration, phase == .running else { return }

        // The receive loop completes establishment when hello.ack arrives;
        // this watchdog fails the generation if it never does.
        establishTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            await self?.establishmentTimedOut(generation: generation)
        }
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(socket: socket, generation: generation)
        }
        // The dial token authenticated this socket; its verified deadline is
        // min(token exp, 15 min). Refresh in-band ahead of it.
        authDeadline = Self.initialAuthDeadline(token: token)
        authTask = Task { [weak self] in
            await self?.authLoop(generation: generation)
        }
    }

    private func dialURL() -> URL? {
        guard
            var components = URLComponents(
                url: configuration.relayBaseURL, resolvingAgainstBaseURL: false)
        else { return nil }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = configuration.role == .host
            ? "/v1/relay/host" : "/v1/relay/connect"
        components.queryItems = [
            URLQueryItem(name: "mac", value: configuration.macDeviceID),
            URLQueryItem(name: "device", value: configuration.selfDeviceID),
        ]
        return components.url
    }

    private func establishmentTimedOut(generation: Int) async {
        guard generation == socketGeneration, phase == .running, !established
        else { return }
        journal("dial-failed", ["reason": "hello-timeout"])
        scheduleRedial(generation: generation)
    }

    private func handleHelloAck(
        legID: UInt32, resumeKey newResumeKey: String, epoch newEpoch: String,
        peerOnline: Bool, replayed: Int, generation: Int
    ) async {
        establishTimeoutTask?.cancel()
        establishTimeoutTask = nil
        let wasResume = resumeKey != nil && everConnected
        assignedLegID = legID
        resumeKey = newResumeKey
        epoch = newEpoch
        established = true
        redialAttempt = 0
        // Rebuild the outbound FIFO from the ledger: every un-acked upload,
        // oldest first (fresh connect flushes frames buffered while dialing;
        // resume fills the relay's ingest gap — the relay dedups sender
        // replays by seq). Anything queued pre-rebuild is un-acked and thus
        // already covered, so the old FIFO is dropped, never double-queued.
        let resend = ledger.framesForResend()
        outboundFIFO = resend.map(\.encoded)
        kickPump()
        journal(
            "up",
            [
                "leg_id": String(legID),
                "resume": wasResume ? "1" : "0",
                "replayed": String(replayed),
                "resent": String(resend.count),
                "peer_online": peerOnline ? "1" : "0",
            ]
        )
        if wasResume {
            continuation?.yield(.resumed(replayedFrames: replayed))
        }
        continuation?.yield(.up(peerOnline: peerOnline))
        resumeDrainWaiters()
        tickTask = Task { [weak self] in
            await self?.tickLoop(generation: generation)
        }
    }

    // MARK: - Receive path

    private func receiveLoop(
        socket: URLSessionWebSocketTask, generation: Int
    ) async {
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                guard generation == socketGeneration, phase == .running else { return }
                await handleSocketFailure(
                    closeCode: socket.closeCode,
                    closeReason: socket.closeReason.flatMap {
                        String(data: $0, encoding: .utf8)
                    } ?? String(describing: error),
                    generation: generation
                )
                return
            }
            guard generation == socketGeneration, phase == .running else { return }
            lastInboundAt = clock.now
            switch message {
            case .string(let text):
                await handleControl(text, generation: generation)
            case .data(let data):
                handleData(data)
            @unknown default:
                break
            }
        }
    }

    private func handleControl(_ text: String, generation: Int) async {
        let frame: DotControlFrame?
        do {
            frame = try DotControlFrame.decode(text)
        } catch {
            journal("control-malformed", ["error": String(describing: error)])
            return
        }
        switch frame {
        case .helloAck(let legID, let resumeKey, let epoch, let peerOnline, let replayed):
            await handleHelloAck(
                legID: legID, resumeKey: resumeKey, epoch: epoch,
                peerOnline: peerOnline, replayed: replayed, generation: generation
            )
        case .resumeFailed(let reason):
            // The relay proved it cannot cover the gap: leg continuity is
            // lost. Re-establish as a FRESH leg (sessions above re-handshake).
            await loseContinuity(reason: "resume-failed: \(reason)")
        case .pong(let ts):
            _ = ts
            if let pingSentAt {
                let rtt = pingSentAt.duration(to: clock.now)
                journal(
                    "pong",
                    ["path": "do:relay", "rtt_ms": String(rtt.milliseconds)],
                    component: "keepalive"
                )
                self.pingSentAt = nil
            }
        case .authOK(let deadlineMS):
            let deadline = Date(timeIntervalSince1970: deadlineMS / 1000)
            authDeadline = deadline
            authOKWaiter?.resume(returning: deadline)
            authOKWaiter = nil
        case .ackUp(let seq, let leg):
            ledger.handleAckUp(seq: seq, leg: leg)
            resumeDrainWaitersIfDrained()
        case .ack:
            // ack is receiver→relay only; the relay never sends it.
            break
        case .peerOnline(let legID, let device):
            continuation?.yield(.peerOnline(legID: legID, device: device))
        case .peerOffline(let legID, let reason):
            continuation?.yield(.peerOffline(legID: legID, reason: reason))
        case .error(let code, let message):
            journal("relay-error", ["code": code, "message": message])
        case .ping(let ts):
            // The relay does not ping clients today; tolerate it silently.
            _ = ts
        case .hello, .authRefresh, nil:
            break
        }
    }

    private func handleData(_ data: Data) {
        guard let frame = DotWire.decodeData(data) else {
            journal("data-malformed", ["bytes": String(data.count)])
            return
        }
        guard ledger.acceptDownload(source: frame.legID, seq: frame.seq) else {
            // Resume overlap replay; drop silently.
            return
        }
        continuation?.yield(.frame(sourceLegID: frame.legID, payload: frame.payload))
        let decision = ledger.ackDecision(source: frame.legID, now: monotonicNow())
        if case .ack(let seq, let leg) = decision {
            sendControl(.ack(seq: seq, leg: leg))
        }
    }

    // MARK: - Watchdogs and keepalive

    private func tickLoop(generation: Int) async {
        wallBaseline = Date()
        monoBaseline = clock.now
        while !Task.isCancelled, generation == socketGeneration, phase == .running {
            try? await Task.sleep(for: .seconds(configuration.keepaliveInterval))
            guard !Task.isCancelled, generation == socketGeneration,
                phase == .running
            else { return }
            // Clock jump: wall time moved far more than monotonic time since
            // the last tick ⇒ the machine slept. The socket is almost
            // certainly dead even if the OS has not said so; redial now.
            let wallElapsed = Date().timeIntervalSince(wallBaseline)
            let monoElapsed = TimeInterval(
                monoBaseline.duration(to: clock.now).milliseconds) / 1000
            wallBaseline = Date()
            monoBaseline = clock.now
            if abs(wallElapsed - monoElapsed) > configuration.clockJumpThreshold {
                await handleSocketFailure(
                    closeCode: .invalid, closeReason: "clock-jump",
                    generation: generation
                )
                return
            }
            // Read liveness: nothing inbound (pongs count) for too long ⇒
            // presume a silent half-open socket and redial with resume.
            let sinceInbound = TimeInterval(
                lastInboundAt.duration(to: clock.now).milliseconds) / 1000
            if sinceInbound > configuration.readLivenessDeadline {
                await handleSocketFailure(
                    closeCode: .invalid, closeReason: "read-liveness",
                    generation: generation
                )
                return
            }
            // Flush coalesced download acks so relay rings stay pruned even
            // on idle streams.
            for decision in ledger.flushAcks(now: monotonicNow()) {
                if case .ack(let seq, let leg) = decision {
                    sendControl(.ack(seq: seq, leg: leg))
                }
            }
            pingSentAt = clock.now
            sendControl(.ping(ts: Date().timeIntervalSince1970 * 1000))
        }
    }

    private func authLoop(generation: Int) async {
        while !Task.isCancelled, generation == socketGeneration, phase == .running {
            let deadline = authDeadline
                ?? Date().addingTimeInterval(Self.authDeadlineCap)
            let refreshAt = deadline.addingTimeInterval(-Self.authRefreshMargin)
            let wait = max(refreshAt.timeIntervalSinceNow, 5)
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, generation == socketGeneration,
                phase == .running, established
            else {
                if generation == socketGeneration, phase == .running { continue }
                return
            }
            do {
                let token = try await configuration.tokenProvider()
                guard generation == socketGeneration, phase == .running else { return }
                sendControl(.authRefresh(token: token))
                let newDeadline = try await awaitAuthOK()
                journal(
                    "auth-refreshed",
                    ["deadline": String(Int(newDeadline.timeIntervalSince1970))]
                )
            } catch {
                guard generation == socketGeneration, phase == .running else { return }
                journal("auth-refresh-failed", ["reason": String(describing: error)])
                // Bounded retry well inside the relay's 60s grace window; if
                // the socket is actually dead the receive loop redials first.
                authDeadline = Date().addingTimeInterval(30 + Self.authRefreshMargin)
            }
        }
    }

    private func awaitAuthOK() async throws -> Date {
        let generation = socketGeneration
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            await self?.failAuthWaiterAfterTimeout(generation: generation)
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            authOKWaiter?.resume(throwing: DotLegError.stopped)
            authOKWaiter = continuation
        }
    }

    private func failAuthWaiterAfterTimeout(generation: Int) {
        guard generation == socketGeneration else { return }
        failAuthWaiter(DotLegError.stopped)
    }

    private func failAuthWaiter(_ error: any Error) {
        authOKWaiter?.resume(throwing: error)
        authOKWaiter = nil
    }

    // MARK: - Failure, resume, reset

    private func handleSocketFailure(
        closeCode: URLSessionWebSocketTask.CloseCode,
        closeReason: String,
        generation: Int
    ) async {
        guard generation == socketGeneration, phase == .running else { return }
        switch UInt16(closeCode.rawValue) {
        case DotWire.closeUnauthorized:
            // The dial token was refused. A fresh dial fetches a fresh token;
            // treat as a suspension so the redial ladder paces retries.
            break
        case DotWire.closeSuperseded:
            // Another leg for this (role, device) took over. Redialing would
            // fight it forever; this leg is done.
            journal("closed", ["reason": "superseded"])
            continuation?.yield(.closed(reason: "superseded"))
            phase = .stopped
            cancelGenerationTasks()
            socket = nil
            resumeDrainWaiters()
            failAuthWaiter(DotLegError.stopped)
            continuation?.finish()
            continuation = nil
            return
        case DotWire.closeCapacity:
            journal("closed", ["reason": "capacity"])
            continuation?.yield(.closed(reason: "capacity"))
            phase = .stopped
            cancelGenerationTasks()
            socket = nil
            resumeDrainWaiters()
            failAuthWaiter(DotLegError.stopped)
            continuation?.finish()
            continuation = nil
            return
        default:
            break
        }
        if everConnected {
            journal(
                "suspended",
                ["reason": closeReason, "close_code": String(closeCode.rawValue)]
            )
            continuation?.yield(.suspended(reason: closeReason))
        } else {
            journal("dial-failed", ["reason": closeReason])
        }
        scheduleRedial(generation: generation)
    }

    /// Resume proof failed or the resend buffer overflowed: every session
    /// over this leg is dead. Restart every stream and re-dial FRESH.
    private func loseContinuity(reason: String) async {
        guard phase == .running else { return }
        journal("reset", ["reason": reason])
        continuation?.yield(.reset(reason: reason))
        ledger.resetForFreshSession()
        resumeKey = nil
        assignedLegID = nil
        established = false
        resumeDrainWaiters()
        journal("dialing", ["trigger": "reset"])
        await dial()
    }

    private func scheduleRedial(generation: Int) {
        guard phase == .running, generation == socketGeneration else { return }
        established = false
        let attempt = redialAttempt
        redialAttempt += 1
        let base = Self.redialBackoff[min(attempt, Self.redialBackoff.count - 1)]
        let delay = base + Double.random(in: 0 ..< base * 0.3)
        journal(
            "redial-scheduled",
            ["attempt": String(attempt), "delay_ms": String(Int(delay * 1000))]
        )
        redialTask?.cancel()
        redialTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.redialNow(generation: generation)
        }
    }

    private func redialNow(generation: Int) async {
        guard phase == .running, generation == socketGeneration else { return }
        journal("dialing", ["trigger": "redial"])
        await dial()
    }

    // MARK: - Helpers

    private func cancelGenerationTasks() {
        receiveTask?.cancel()
        receiveTask = nil
        tickTask?.cancel()
        tickTask = nil
        authTask?.cancel()
        authTask = nil
        establishTimeoutTask?.cancel()
        establishTimeoutTask = nil
        // The cancelled auth loop may be parked on this continuation; unpark
        // it so the task can actually exit.
        failAuthWaiter(DotLegError.stopped)
    }

    /// Fire-and-forget control send; the receive loop owns failure handling.
    private func sendControl(_ frame: DotControlFrame) {
        guard let socket, established else { return }
        guard let text = try? frame.encoded() else { return }
        Task {
            try? await socket.send(.string(text))
        }
    }

    private func resumeDrainWaiters() {
        let waiters = drainWaiters
        drainWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func resumeDrainWaitersIfDrained() {
        guard ledger.totalBufferedBytes <= Self.sendGateBytes else { return }
        resumeDrainWaiters()
    }

    private func monotonicNow() -> TimeInterval {
        TimeInterval(startedAt.duration(to: clock.now).milliseconds) / 1000
    }

    /// The relay's initial verified deadline: token `exp` capped at 15 min.
    private static func initialAuthDeadline(token: String) -> Date {
        let cap = Date().addingTimeInterval(authDeadlineCap)
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
            let payload = Data(base64URLOrStandard: String(segments[1])),
            let object = try? JSONSerialization.jsonObject(with: payload)
                as? [String: Any],
            let exp = (object["exp"] as? NSNumber)?.doubleValue
        else { return cap }
        return min(Date(timeIntervalSince1970: exp), cap)
    }

    private func journal(
        _ event: String,
        _ attributes: [String: String] = [:],
        component: String = "leg"
    ) {
        var attributes = attributes
        attributes["role"] = configuration.role.rawValue
        configuration.journal.record(
            component: component, event: event, attributes: attributes
        )
    }
}

extension Duration {
    var milliseconds: Int64 {
        components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
    }
}
