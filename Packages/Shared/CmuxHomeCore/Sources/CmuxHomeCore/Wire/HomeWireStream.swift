import Foundation

/// One subscribed `cmux.wire/1` stream over a WebSocket that dials again
/// after every drop (cmux-tui-cloud-conversations `stream.rs`, client side):
///
/// - On `welcome` it sends `subscribe`, with `after_seq` once it holds a
///   position, so the owner replays only what was missed (or sends a
///   snapshot when it cannot). Another principal drops the position.
/// - An `event` whose seq is not the next one is a gap: it sends
///   `snapshot.request` and drops events until the snapshot comes. A repeat
///   is dropped. So ``events`` carries each snapshot and event once, in order.
/// - A drop waits 1, 2, 4, 8, 16 then 30 s between dials (a welcome starts
///   again at 1 s). A 4401 close or a 401 upgrade means the token expired:
///   the next dial asks for a new one. A 403 or 404 upgrade, or an
///   `auth.forbidden` error, stops the stream (`.refused`).
/// - A ping goes out only after 25 s with no frame from the owner
///   (``HomeKeepaliveSchedule``); one that gets no answer closes the socket.
/// - Ops never go on the socket: ``WireHomeSource`` sends them over HTTP,
///   as the daemon does, so `result`, `reject` and `request-settled` frames
///   are ignored.
actor HomeWireStream {
    let target: HomeWireStreamTarget
    /// What the socket brought, in order; finishes when the stream stops.
    nonisolated let events: AsyncStream<HomeWireStreamEvent>
    private let continuation: AsyncStream<HomeWireStreamEvent>.Continuation
    private let client: HomeWireClient
    private let sockets: any HomeWireSocketConnecting
    private let clock: any Clock<Duration>
    /// Time on ``clock`` since the stream was made: the keepalive's ping and inbound times.
    private let elapsed: @Sendable () -> Duration
    private var loop: Task<Void, Never>?
    private var socket: (any HomeWireSocket)?
    private var wait: Task<Void, Never>?
    private var stopped = false
    /// The principal of the last `welcome`.
    private var user: String?
    /// The last stream seq handed on (snapshot or event); a resume starts after it.
    private var lastSeq: UInt64?
    private var awaitingSnapshot = false
    /// The subscribe went out on the current socket.
    private var subscribed = false
    /// When the owner last sent a frame, on ``elapsed``: it pushes the next keepalive ping out.
    private var lastInbound: Duration?
    /// The quiet time on a socket before a keepalive ping.
    static let keepaliveInterval: Duration = .seconds(25)

    init(target: HomeWireStreamTarget, client: HomeWireClient, sockets: any HomeWireSocketConnecting,
         clock: any Clock<Duration>) {
        self.target = target
        self.client = client
        self.sockets = sockets
        self.clock = clock
        elapsed = Self.stopwatch(clock)
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    /// Starts dialing (idempotent).
    func start() {
        guard loop == nil, !stopped else { return }
        loop = Task { await self.run() }
    }

    /// Stops for good: closes the socket and finishes ``events``.
    func stop() {
        guard !stopped else { return }
        stopped = true
        loop?.cancel()
        wait?.cancel()
        socket?.close()
        socket = nil
        continuation.finish()
    }

    /// Dials now when the stream waits between dials (foreground, or the
    /// network came back); the backoff starts again from 1 s.
    func reconnectNow() {
        wait?.cancel()
    }

    /// Sends `{t: "typing", on}` on the live socket; false without one.
    func sendTyping(_ on: Bool) async -> Bool {
        guard subscribed, let socket else { return false }
        var frame: [String: HomeWireJSON] = ["t": "typing", "on": .bool(on)]
        if case .conversation(let id) = target { frame["conversation"] = .string(id.rawValue) }
        do {
            try await socket.send(HomeWireJSON.object(frame).text)
            return true
        } catch {
            return false
        }
    }

    /// Asks the owner for a snapshot now (a frame the source could not use).
    func resync() async {
        guard subscribed, let socket else { return }
        try? await askSnapshot(on: socket)
    }

    // MARK: Dialing

    private enum End {
        case ended(welcomed: Bool, unauthorized: Bool)
        case refused(String)
    }

    private struct Refused: Error {
        let reason: String
    }

    private func run() async {
        var attempt = 0
        var forceRefresh = false
        while !stopped, !Task.isCancelled {
            let end = await connectOnce(forceRefresh: forceRefresh)
            subscribed = false
            guard !stopped, !Task.isCancelled else { return }
            switch end {
            case .refused(let reason):
                continuation.yield(.refused(reason))
                stop()
                return
            case .ended(let welcomed, let unauthorized):
                continuation.yield(.disconnected)
                if welcomed { attempt = 0 }
                forceRefresh = unauthorized
            }
            let delay = reconnectDelay(attempt: attempt)
            attempt += 1
            let clock = self.clock
            // task-owner: the wait between dials; `reconnectNow` and `stop` cancel it
            let pause = Task {
                // wakeup-allow: backoff 1 s doubling to 30 s between dials after a drop; `reconnectNow` and `stop` cancel it
                _ = try? await clock.sleep(for: delay, tolerance: HomeWakeLeeway(delay: delay).tolerance)
            }
            wait = pause
            await pause.value
            wait = nil
            if pause.isCancelled { attempt = 0 }
        }
    }

    private func connectOnce(forceRefresh: Bool) async -> End {
        let request: URLRequest
        do {
            request = try await client.socketRequest(target.path, forceRefresh: forceRefresh)
        } catch {
            return .ended(welcomed: false, unauthorized: false)
        }
        guard !stopped, !Task.isCancelled else { return .ended(welcomed: false, unauthorized: false) }
        let socket = sockets.connect(request)
        self.socket = socket
        awaitingSnapshot = false
        subscribed = false
        let pinger = Task { await self.keepAlive(socket) }
        defer {
            pinger.cancel()
            socket.close()
            if self.socket === socket { self.socket = nil }
        }
        var welcomed = false
        do {
            while !stopped, !Task.isCancelled {
                let text = try await socket.receive()
                lastInbound = elapsed()
                if try await handle(text, on: socket) { welcomed = true }
            }
            return .ended(welcomed: welcomed, unauthorized: false)
        } catch let refusal as Refused {
            return .refused(refusal.reason)
        } catch {
            if !welcomed, let status = socket.upgradeStatus {
                if status == 403 || status == 404 { return .refused("http_\(status)") }
                if status == 401 { return .ended(welcomed: false, unauthorized: true) }
            }
            return .ended(welcomed: welcomed, unauthorized: socket.closeCode == 4401)
        }
    }

    /// Pings after ``keepaliveInterval`` with no frame from the owner; a socket that stops answering
    /// is closed, so the loop dials again.
    private func keepAlive(_ socket: any HomeWireSocket) async {
        let schedule = HomeKeepaliveSchedule(interval: Self.keepaliveInterval)
        var lastPing = elapsed()
        // wakeup-allow: deadline one ping deadline at a time, `keepaliveInterval` after the last ping or
        // the owner's last frame; frames push it out, the socket's end cancels it.
        while !Task.isCancelled {
            let remaining = schedule.nextPing(afterPing: lastPing, lastInbound: lastInbound) - elapsed()
            if remaining > .zero {
                // wakeup-allow: deadline the next ping's due time, with leeway; on waking the loop reads
                // the due time again, because the owner's frames may have pushed it out.
                do { try await clock.sleep(for: remaining, tolerance: HomeWakeLeeway(delay: remaining).tolerance) } catch { return }
                continue
            }
            guard await socket.ping() else {
                socket.close()
                return
            }
            lastPing = elapsed()
        }
    }

    /// Time on `clock` since this call. The clock's instants stay inside the closure, so the actor
    /// keeps plain durations and never opens the existential clock in an async call.
    private static func stopwatch<C: Clock<Duration>>(_ clock: C) -> @Sendable () -> Duration {
        let start = clock.now
        return { start.duration(to: clock.now) }
    }

    // MARK: Frames

    /// One owner frame; true for `welcome`.
    private func handle(_ text: String, on socket: any HomeWireSocket) async throws -> Bool {
        guard let frame = HomeWireJSON.parse(text) else { return false }
        switch frame["t"].string {
        case "welcome":
            let principal = frame["principal"]["user"].string.flatMap { $0.isEmpty ? nil : $0 }
            if let principal {
                // Another account: never resume a position it may not own.
                if user != principal { lastSeq = nil }
                user = principal
            } else {
                // The inbox stream is named after the principal.
                if target == .inbox { throw Refused(reason: "no_principal") }
                lastSeq = nil
                user = nil
            }
            var subscribe = streamFrame("subscribe")
            let resumed = lastSeq != nil
            if let lastSeq { subscribe["after_seq"] = .uint(lastSeq) }
            try await socket.send(HomeWireJSON.object(subscribe).text)
            subscribed = true
            continuation.yield(.welcome(user: user, resumed: resumed))
            return true
        case "snapshot":
            guard subscribed, isMine(frame), let seq = frame["seq"].uint else { return false }
            lastSeq = seq
            awaitingSnapshot = false
            continuation.yield(.snapshot(frame))
        case "event":
            guard subscribed, isMine(frame), !awaitingSnapshot, let seq = frame["seq"].uint else { return false }
            guard let last = lastSeq else {
                try await askSnapshot(on: socket)
                return false
            }
            guard seq > last else { return false }
            guard seq == last + 1 else {
                try await askSnapshot(on: socket)
                return false
            }
            lastSeq = seq
            continuation.yield(.event(frame))
        case "conversation-typing":
            continuation.yield(.typing(frame))
        case "error":
            if frame["code"].string == "auth.forbidden" { throw Refused(reason: "auth.forbidden") }
        default:
            break
        }
        return false
    }

    private func askSnapshot(on socket: any HomeWireSocket) async throws {
        guard !awaitingSnapshot else { return }
        awaitingSnapshot = true
        var request = streamFrame("snapshot.request")
        request["pending"] = []
        try await socket.send(HomeWireJSON.object(request).text)
    }

    /// A client frame; the inbox names its stream on every frame.
    private func streamFrame(_ kind: String) -> [String: HomeWireJSON] {
        var frame: [String: HomeWireJSON] = ["t": .string(kind)]
        if target == .inbox, let name = target.streamName(user: user) { frame["stream"] = .string(name) }
        return frame
    }

    private func isMine(_ frame: HomeWireJSON) -> Bool {
        guard let stream = frame["stream"].string, let expected = target.streamName(user: user) else { return false }
        return stream == expected
    }
}

/// The wait after the `attempt`th failed dial in a row: 1, 2, 4, 8, 16, then 30 s.
func reconnectDelay(attempt: Int) -> Duration {
    attempt >= 5 ? .seconds(30) : .seconds(1 << max(0, attempt))
}
