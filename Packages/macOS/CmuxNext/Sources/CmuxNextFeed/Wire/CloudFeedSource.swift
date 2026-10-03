public import Foundation
import CmuxNextWakeups

/// The `FeedDO` stream over `cmux.wire/1` (`/v1/wire/feed`, plans/cmux-next/feed.md
/// sections 4 and 6). The owner sends a snapshot on subscribe and, on every
/// commit, an event that carries the items the commit changed; this source
/// turns those into `FeedSourceEvent`s and never replays ops itself. Intents go
/// out as `op` frames with origin `user`; an intent sent before a disconnect is
/// resent with the same key after the reconnect (the owner's ledger answers a
/// decided key from the ledger); nothing new is sent while disconnected.
@MainActor
public final class CloudFeedSource: FeedSource {
    /// Returns a fresh bearer token (a Stack session token today; an install token later).
    public typealias TokenProvider = @Sendable () async throws -> String

    private let wireURL: URL
    private let token: TokenProvider
    private let device: String
    private var sink: (@MainActor (FeedSourceEvent) -> Void)?
    private var runner: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    /// Bumped by every start, stop and reset: a finishing older connection never touches newer state.
    private var generation = 0
    private var probe: Task<Void, Never>?
    private var stream = ""
    private var connected = false
    private var active = false
    /// Frames of intents sent and not settled, in send order (resent in that order on reconnect).
    private var unsettled: [(key: String, frame: [String: Any])] = []
    private var rejects: [String: FeedReject] = [:]
    /// Unread items and when they were posted, for `markAllRead`.
    private var unread: [String: Date] = [:]
    private var known: Set<String> = []

    public init(apiBaseURL: URL, device: String, token: @escaping TokenProvider) {
        var c = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        c.scheme = c.scheme == "http" ? "ws" : "wss"
        c.path = "/v1/wire/feed"
        wireURL = c.url ?? apiBaseURL
        self.device = device
        self.token = token
    }

    public func start(_ sink: @escaping @MainActor (FeedSourceEvent) -> Void) {
        self.sink = sink
        runner?.cancel()
        generation += 1
        let generation = generation
        runner = Task { await self.run(generation) }
    }

    public func stop() {
        generation += 1
        runner?.cancel()
        runner = nil
        probe?.cancel()
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
        probe?.cancel()
        let generation = generation
        let answered = PingState()
        socket.sendPing { error in
            Task { @MainActor in
                answered.done = true
                if error != nil, generation == self.generation { socket.cancel(with: .goingAway, reason: nil) }
            }
        }
        // task-owner: CloudFeedSource.probe, one-shot pong deadline, cancelled by the next probe or stop.
        probe = Task {
            // wakeup-allow: one-shot 10 s pong deadline after a wake, network change or send; not periodic.
            try? await ContinuousClock().sleep(for: .seconds(10))
            if !Task.isCancelled, !answered.done, generation == self.generation { socket.cancel(with: .goingAway, reason: nil) }
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
        var backoff = Backoff(initial: .milliseconds(500), maximum: .seconds(30))
        // wakeup-allow: one pass per connection; each pass awaits the socket and, after a failure, a Backoff delay.
        while !Task.isCancelled {
            sink?(.connection(.connecting))
            var reason = "closed"
            do {
                try await session(onSnapshot: { backoff.reset() })
            } catch is CancellationError {
                return
            } catch {
                reason = String(describing: error)
            }
            guard generation == self.generation else { return }
            connected = false
            socket = nil
            sink?(.connection(.disconnected(reason)))
            // concurrency-allow: Backoff.wait is an async sleep after a failure, not a blocking wait.
            do { try await backoff.wait(owner: "feed.cloud.reconnect") } catch { return }
        }
    }

    private func session(onSnapshot: () -> Void) async throws {
        var request = URLRequest(url: wireURL)
        request.setValue("cmux.wire.v1, bearer.\(try await token())", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let task = URLSession.shared.webSocketTask(with: request)
        // A full snapshot is up to 1.5 MB (the owner's state bound); the default limit is 1 MiB.
        task.maximumMessageSize = 8 << 20
        socket = task
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }
        // wakeup-allow: each turn awaits the next frame; a closed socket throws and ends the loop.
        while !Task.isCancelled {
            let message = try await task.receive()
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
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let t = o["t"] as? String else { return .ignored }
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

/// Whether a ping got its pong (main actor only).
@MainActor
private final class PingState {
    var done = false
}
