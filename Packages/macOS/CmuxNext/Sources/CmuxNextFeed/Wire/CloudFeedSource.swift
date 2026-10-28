import CmuxNextCompat
public import Foundation
public import CmuxNextWakeups

/// The `FeedDO` stream over `cmux.wire/1` (`/v1/wire/feed`, plans/cmux-next/feed.md
/// sections 4 and 6). The owner sends a snapshot on subscribe and, on every
/// commit, an event that carries the items the commit changed; this source
/// turns those into `FeedSourceEvent`s and never replays ops itself. Intents go
/// out as `op` frames with origin `user`; an intent sent before a disconnect is
/// resent with the same key after the reconnect (the owner's ledger answers a
/// decided key from the ledger); nothing new is sent while disconnected.
///
/// With the app's Energy Saver policy (``KeepaliveGate``) a sleep of the Mac or its
/// displays drops a pending pong deadline (its 10 s would run through the sleep), and a wake that
/// finds the network closes the socket once and reconnects within ``EnergyPolicy/reconnectJitter``.
@MainActor
public final class CloudFeedSource: FeedSource {
    /// Returns a fresh bearer token (a Stack session token today; an install token later).
    public typealias TokenProvider = @Sendable () async throws -> String
    /// One wire connection with `bearer`: returns or throws when the socket closes, calls
    /// `onSnapshot` when a snapshot made the mirror current, and hands `opened` the closer a wake's
    /// reconnect uses. Tests pass a fake; nil is the socket.
    typealias Connect = @MainActor (_ bearer: String, _ onSnapshot: () -> Void,
                                    _ opened: (_ close: @escaping @Sendable () -> Void) -> Void) async throws -> Void
    /// The wire upgrade was answered 401: the server refused this token.
    nonisolated struct Unauthorized: Error, Sendable {}
    /// The disconnected reason while the loop holds a token the server refused.
    static let unauthorizedReason = "the server refused this sign-in token; waiting for a new one"

    private let wireURL: URL
    private let token: TokenProvider
    private let connect: Connect?
    private let reconnect: Backoff
    /// Sleep and wake from the app's Energy Saver policy; with no policy it never pauses or reconnects.
    private let gate: KeepaliveGate
    /// The wait between connections (``KeepaliveGate/retryWait(_:timer:)``).
    private let retry: DemandTimer
    private let device: String
    private var sink: (@MainActor (FeedSourceEvent) -> Void)?
    private var runner: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    /// Bumped by every start, stop and reset: a finishing older connection never touches newer state.
    private var generation = 0
    /// The pong deadline of the latest ``checkAlive()``: a later probe replaces it, its pong drops it.
    private let probe: DemandTimer
    /// The app's main-thread scheduler: a ping's answer is one background task on it.
    private let mainWork: MainWorkScheduler
    /// Counts probes, so only the latest one's pong drops the deadline.
    private var probes = 0
    /// How long ``checkAlive()`` waits for the pong; a flexible deadline (WakeLeeway: 1 s leeway).
    static let pongLimit: Duration = .seconds(10)
    private var stream = ""
    private var connected = false
    private var active = false
    /// Frames of intents sent and not settled, in send order (resent in that order on reconnect).
    private var unsettled: [(key: String, frame: [String: Any])] = []
    private var rejects: [String: FeedReject] = [:]
    /// Unread items and when they were posted, for `markAllRead`.
    private var unread: [String: Date] = [:]
    private var known: Set<String> = []

    /// `energy` is the app's Energy Saver policy (`MainWorkScheduler.energy`); nil keeps the socket as if always awake.
    /// `mainWork` is the app's one main-thread scheduler: a ping's answer from URLSession's queue is posted on it.
    public convenience init(apiBaseURL: URL, device: String, energy: EnergyPolicySource? = nil, mainWork: MainWorkScheduler,
                            token: @escaping TokenProvider) {
        self.init(apiBaseURL: apiBaseURL, device: device, mainWork: mainWork, token: token,
                  reconnect: Backoff(initial: .milliseconds(500), maximum: .seconds(30)), connect: nil, energy: energy)
    }

    init(apiBaseURL: URL, device: String, mainWork: MainWorkScheduler, token: @escaping TokenProvider, reconnect: Backoff, connect: Connect?,
         clock: any Clock<Duration> = ContinuousClock(), energy: EnergyPolicySource? = nil,
         wakeJitter: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) {
        self.mainWork = mainWork
        var c = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        c.scheme = c.scheme == "http" ? "ws" : "wss"
        c.path = "/v1/wire/feed"
        wireURL = c.url ?? apiBaseURL
        self.device = device
        self.token = token
        self.reconnect = reconnect
        self.connect = connect
        // timer-class-allow: off-main: the pong deadline only cancels the probed socket (thread-safe) and runs no main-thread job.
        probe = DemandTimer(owner: "CloudFeedSource.pong", clock: clock)
        // timer-class-allow: off-main: the retry deadline only resolves the gate's wait (thread-safe); the run loop resumes on its own actor.
        retry = DemandTimer(owner: "feed.cloud.reconnect", clock: clock)
        gate = KeepaliveGate(energy, random: wakeJitter)
        gate.follow { [probe] edge in if edge == .pause { probe.cancel() } }
    }

    public func start(_ sink: @escaping @MainActor (FeedSourceEvent) -> Void) {
        self.sink = sink
        runner?.cancel()
        probe.cancel()
        generation += 1
        let generation = generation
        // task-owner: `runner`; the connection loop of this generation; stop() and reset() cancel it
        // main-hop-allow: the feed's main-actor connection loop (its awaits are the token, the socket and its Backoff); frames apply in order to the main-actor mirror and sink
        runner = Task { await self.run(generation) }
    }

    public func stop() {
        generation += 1
        runner?.cancel()
        runner = nil
        probe.cancel()
        gate.closed()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        connected = false
    }

    /// Sign-out or an account change: stops, forgets every intent and item,
    /// and shows an empty, disconnected feed until the next `start`.
    public func reset(reason: String) {
        stop()
        unsettled = []
        rejects = [:]
        unread = [:]
        known = []
        stream = ""
        sink?(.connection(.disconnected(reason)))
        sink?(.snapshot(FeedSnapshot(revision: 0, user: "", device: device, items: [])))
    }

    /// Checks that the socket is alive (after a wake, a network change or a send):
    /// no pong within 10 s closes it, and the run loop reconnects.
    public func checkAlive() {
        guard let socket, connected else { return }
        let answer = armPongLimit { socket.cancel(with: .goingAway, reason: nil) }
        let mainWork = mainWork
        socket.sendPing { error in
            let failed = error != nil
            // R-hop: the pong (or a failed ping) comes on URLSession's queue; its answer only drops or fires the deadline.
            mainWork.postFromAnyThread(.background, owner: Self.pongOwner) { answer(failed) }
        }
    }

    /// The ping answers' owner in the board and the wakeup ledger.
    nonisolated static let pongOwner = "CloudFeedSource.pong"

    /// Arms one probe's pong deadline: `close` runs at ``pongLimit``, off the main actor, unless the
    /// returned answer, a later probe, a start or a stop comes first. A failed ping closes at once and
    /// the latest probe's pong drops the deadline, while the connection that sent the ping is current.
    func armPongLimit(close: @escaping @Sendable () -> Void) -> @MainActor @Sendable (_ failed: Bool) -> Void {
        probes += 1
        let id = probes
        let generation = generation
        probe.schedule(after: Self.pongLimit) { close() }
        return { [weak self] failed in
            guard let self, generation == self.generation else { return }
            if failed { close() } else if id == probes { probe.cancel() }
        }
    }

    public func send(_ intent: FeedIntent) {
        guard connected else {
            sink?(.settled(key: intent.key, reject: .disconnected))
            return
        }
        let unread = self.unread
        guard let (op, params) = FeedWireEncode.op(intent, unreadBefore: { cut in unread.filter { $0.value <= cut }.map(\.key).sorted() }) else {
            sink?(.settled(key: intent.key, reject: nil))
            return
        }
        let frame: [String: Any] = ["t": "op", "op": op, "params": params, "idempotency_key": intent.key, "origin": "user"]
        unsettled.append((intent.key, frame))
        write(frame)
        checkAlive()
    }

    /// The app's active state for the owner's push rule (a Mac in use gets banners, not iPhone pushes).
    public func setPresence(active: Bool) {
        self.active = active
        if connected { writePresence() }
    }

    // MARK: - Connection

    private func run(_ generation: Int) async {
        var backoff = reconnect
        /// The token a 401 refused: no socket opens with it again. The loop asks the provider on
        /// the Backoff schedule (no request reaches the server) until it returns another token;
        /// a sign-in or account change also restarts the loop through `start` or `reset`.
        var refused: String?
        // wakeup-allow: one pass per connection; each pass awaits the socket and, after a failure, a Backoff delay.
        while !Task.isCancelled {
            var reason = "closed"
            var bearer: String?
            do {
                let next = try await token()
                guard generation == self.generation else { return }
                if next == refused {
                    // concurrency-allow: Backoff.wait is an async sleep while the token is refused, not a blocking wait.
                    do { try await backoff.wait(owner: "feed.cloud.unauthorized") } catch { return }
                    continue
                }
                refused = nil
                bearer = next
                sink?(.connection(.connecting))
                if let connect {
                    try await connect(next, { backoff.reset() }, { [gate] close in gate.opened(close: close) })
                } else {
                    try await session(bearer: next) { backoff.reset() }
                }
            } catch is CancellationError {
                return
            } catch is Unauthorized {
                refused = bearer
                reason = Self.unauthorizedReason
            } catch {
                reason = String(describing: error)
            }
            guard generation == self.generation else { return }
            gate.closed()
            connected = false
            socket = nil
            sink?(.connection(.disconnected(reason)))
            // concurrency-allow: the gate's retry wait is a one-shot DemandTimer (Backoff's step after a failure, or the short wait after a wake), not a blocking wait.
            do { try await gate.retryWait(&backoff, timer: retry) } catch { return }
        }
    }

    /// This app's version (`CFBundleShortVersionString`), sent on every wire connect.
    static let clientVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    /// The token goes only in the Authorization header, which Workers invocation logs never record
    /// (cx-dgsp). The legacy `bearer.` subprotocol is retired: a 401 is final for this token, and
    /// the run loop opens no socket with it again (`Unauthorized`).
    private func session(bearer: String, onSnapshot: () -> Void) async throws {
        var request = URLRequest(url: wireURL)
        request.setValue("cmux.wire.v1", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        // updates.minimumVersion (enterprise P17-4): the server refuses older clients with client.too_old.
        if let version = Self.clientVersion { request.setValue(version, forHTTPHeaderField: "x-cmux-client-version") }
        let task = URLSession.shared.webSocketTask(with: request)
        // A full snapshot is up to 1.5 MB (the owner's state bound); the default limit is 1 MiB.
        task.maximumMessageSize = 8 << 20
        socket = task
        task.resume()
        gate.opened { task.cancel(with: .goingAway, reason: nil) }
        defer { task.cancel(with: .goingAway, reason: nil) }
        // wakeup-allow: each turn awaits the next frame; a closed socket throws and ends the loop.
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                // A refused upgrade fails the first receive; its HTTP answer is the task's response.
                if (task.response as? HTTPURLResponse)?.statusCode == 401 { throw Unauthorized() }
                throw error
            }
            let data: Data
            switch message {
            case let .string(text): data = Data(text.utf8)
            case let .data(bytes): data = bytes
            @unknown default: continue
            }
            let frame = await Task.detached(priority: .userInitiated) { FeedWireFrame.decode(data) }.value
            if handle(frame) { onSnapshot() }
        }
        throw CancellationError()
    }

    /// Applies one decoded frame; returns true when a snapshot made the mirror current.
    private func handle(_ frame: FeedWireFrame) -> Bool {
        switch frame {
        case let .welcome(user):
            stream = "feed:\(user)"
            // No `after_seq`: resumed log events carry no items, so a (re)subscribe always takes the snapshot.
            write(["t": "subscribe", "stream": stream, "pending": unsettled.map(\.key)])
        case let .snapshot(seq, user, items):
            connected = true
            known = Set(items.map(\.id))
            unread = Dictionary(items.filter(\.isUnread).map { ($0.id, $0.createdAt) }, uniquingKeysWith: { a, _ in a })
            sink?(.connection(.connected))
            sink?(.snapshot(FeedSnapshot(revision: seq, user: user, device: device, items: items)))
            writePresence()
            for entry in unsettled { write(entry.frame) }
            return true
        case let .event(seq, items, present):
            for item in items {
                known.insert(item.id)
                unread[item.id] = item.isUnread ? item.createdAt : nil
            }
            if !items.isEmpty { sink?(.event(FeedEvent(revision: seq, change: .items(items)))) }
            if let present {
                let gone = known.subtracting(present)
                if !gone.isEmpty {
                    known.subtract(gone)
                    for id in gone { unread[id] = nil }
                    sink?(.event(FeedEvent(revision: seq, change: .remove(gone.sorted()))))
                }
            }
        case let .reject(key, reject):
            rejects[key] = reject
        case let .settled(key):
            let reject = rejects.removeValue(forKey: key)
            guard let index = unsettled.firstIndex(where: { $0.key == key }) else { break }
            unsettled.remove(at: index)
            sink?(.settled(key: key, reject: reject))
        case .ignored:
            break
        }
        return false
    }

    private func writePresence() {
        guard !stream.isEmpty else { return }
        write(["t": "presence.set", "stream": stream, "state": ["active": active, "client": "mac"]])
    }

    private func write(_ frame: [String: Any]) {
        guard let socket, JSONSerialization.isValidJSONObject(frame), let data = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }
}

/// One `cmux.wire/1` frame from the feed owner, decoded off the main actor.
nonisolated enum FeedWireFrame: Sendable {
    case welcome(user: String)
    case snapshot(seq: UInt64, user: String, items: [FeedItem])
    case event(seq: UInt64, items: [FeedItem], present: [String]?)
    case reject(key: String, FeedReject)
    case settled(key: String)
    case ignored

    static func decode(_ data: Data) -> FeedWireFrame {
        guard let o = (try? JSONSerialization.blockingJSONObject(with: data)) as? [String: Any], let t = o["t"] as? String else { return .ignored }
        let seq = (o["seq"] as? Int).flatMap { UInt64(exactly: $0) } ?? 0
        switch t {
        case "welcome":
            return ((o["principal"] as? [String: Any])?["user"] as? String).map { .welcome(user: $0) } ?? .ignored
        case "snapshot":
            let state = o["state"] as? [String: Any] ?? [:]
            let items = (state["items"] as? [String: Any] ?? [:]).values.compactMap { ($0 as? [String: Any]).flatMap(FeedWireDecode.item) }
            return .snapshot(seq: seq, user: state["user"] as? String ?? "", items: items)
        case "event":
            let items = ((o["items"] as? [[String: Any]]) ?? []).compactMap(FeedWireDecode.item)
            return .event(seq: seq, items: items, present: o["present"] as? [String])
        case "reject":
            guard let key = o["idempotency_key"] as? String else { return .ignored }
            return .reject(key: key, FeedWireEncode.reject(code: o["code"] as? String ?? "", message: o["message"] as? String ?? "",
                                                           details: o["details"] as? [String: Any]))
        case "request-settled":
            return (o["idempotency_key"] as? String).map { .settled(key: $0) } ?? .ignored
        default:
            return .ignored
        }
    }
}
