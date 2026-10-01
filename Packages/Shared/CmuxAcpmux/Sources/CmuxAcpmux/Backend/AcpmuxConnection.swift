import CmuxConversation
import Foundation

/// The control connection to one acpmux daemon. Connects, reconnects with
/// backoff, routes notifications to open feeds and keeps the session list.
actor AcpmuxConnection {
    private let opener: any ConversationStreamOpening
    private let clientName: String
    private let clock: any Clock<Duration>
    private let maximumBackoff: Duration
    private let decoder = AcpmuxEventDecoder()
    private(set) var client: AcpmuxRPCClient?
    private var runTask: Task<Void, Never>?
    private var state: BackendConnectionState = .connecting
    private var stateSubscribers: [UUID: AsyncStream<BackendConnectionState>.Continuation] = [:]
    private var list: [String: ConversationSummary] = [:]
    private var listSubscribers: [UUID: AsyncStream<[ConversationSummary]>.Continuation] = [:]
    private var feeds: [String: AcpmuxFeed] = [:]
    private var readyWaiters: [CheckedContinuation<AcpmuxRPCClient, any Error>] = []

    init(opener: any ConversationStreamOpening, clientName: String, clock: any Clock<Duration>, maximumBackoff: Duration) {
        self.opener = opener
        self.clientName = clientName
        self.clock = clock
        self.maximumBackoff = maximumBackoff
    }

    func start() {
        guard runTask == nil else { return }
        runTask = Task { await self.run() }
    }

    func stop() async {
        runTask?.cancel()
        await client?.close()
    }

    // MARK: - Subscriptions

    func states() -> AsyncStream<BackendConnectionState> {
        let id = UUID()
        let (s, c) = AsyncStream<BackendConnectionState>.makeStream(bufferingPolicy: .bufferingNewest(8))
        c.yield(state)
        stateSubscribers[id] = c
        c.onTermination = { _ in Task { await self.dropState(id) } }
        start()
        return s
    }

    private func dropState(_ id: UUID) { stateSubscribers[id] = nil }

    func sessions() -> AsyncStream<[ConversationSummary]> {
        let id = UUID()
        let (s, c) = AsyncStream<[ConversationSummary]>.makeStream(bufferingPolicy: .bufferingNewest(2))
        c.yield(sortedList())
        listSubscribers[id] = c
        c.onTermination = { _ in Task { await self.dropList(id) } }
        start()
        return s
    }

    private func dropList(_ id: UUID) { listSubscribers[id] = nil }

    private func sortedList() -> [ConversationSummary] {
        list.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func publishList() {
        let l = sortedList()
        for c in listSubscribers.values { c.yield(l) }
    }

    private func setState(_ s: BackendConnectionState) {
        state = s
        for c in stateSubscribers.values { c.yield(s) }
    }

    /// The connected client, waiting for the connection if needed.
    func connectedClient() async throws -> AcpmuxRPCClient {
        if let client { return client }
        if case let .incompatible(reason) = state { throw ConversationBackendError.unsupported(reason) }
        start()
        return try await withCheckedThrowingContinuation { readyWaiters.append($0) }
    }

    func register(_ feed: AcpmuxFeed, for sessionID: String) async {
        feeds[sessionID] = feed
        if let client {
            await feed.connected(client)
        }
    }

    func unregister(_ sessionID: String) { feeds[sessionID] = nil }

    func openFeeds() -> [String: AcpmuxFeed] { feeds }

    // MARK: - Loop

    private func backoff(_ attempt: Int) -> Duration {
        let base = Duration.milliseconds(250) * (1 << min(attempt, 12))
        return min(base, maximumBackoff)
    }

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            setState(.connecting)
            do {
                let stream = try await opener.open(.control)
                let c = AcpmuxRPCClient(stream: stream, clock: clock)
                await c.start()
                let notes = c.notifications
                let hello = try await c.request("initialize", .object(["protocolVersion": .number(1), "clientInfo": .object(["name": .string(clientName)])]))
                let version = hello["agentInfo"]?["version"]?.stringValue ?? ""
                let schema = try await c.request("_acpmux/schema", .object([:]))
                guard let caps = AcpmuxRequirements().capabilities(schema: schema, version: version) else {
                    await c.close()
                    let reason = "acpmux \(version) lacks methods this client needs"
                    setState(.incompatible(reason: reason))
                    failWaiters(ConversationBackendError.unsupported(reason))
                    return
                }
                let watch = try await c.request("_acpmux/watch", .object(["enabled": .bool(true)]))
                list = [:]
                for v in watch["sessions"]?.arrayValue ?? [] {
                    if let s = decoder.summary(v) { list[s.id.rawValue] = s }
                }
                publishList()
                client = c
                attempt = 0
                setState(.connected(caps))
                for w in readyWaiters { w.resume(returning: c) }
                readyWaiters.removeAll()
                for feed in feeds.values {
                    await feed.connected(c)
                }
                for await n in notes {
                    await route(n)
                }
                client = nil
                await c.close()
                for feed in feeds.values {
                    await feed.disconnected()
                }
                setState(.disconnected(reason: "acpmux connection closed"))
            } catch {
                client = nil
                setState(.disconnected(reason: String(describing: error)))
            }
            attempt += 1
            do {
                // Backoff after a failed connect, never a poll.
                try await clock.sleep(for: backoff(attempt))
            } catch {
                return
            }
        }
    }

    private func failWaiters(_ error: any Error) {
        for w in readyWaiters { w.resume(throwing: error) }
        readyWaiters.removeAll()
    }

    private func route(_ n: AcpmuxNotification) async {
        switch n.method {
        case "_acpmux/session_changed":
            let kind = n.params["kind"]?.stringValue
            guard let summary = n.params["session"], let id = summary["sessionId"]?.stringValue else { return }
            if kind == "purged" {
                list[id] = nil
                await feeds[id]?.deleted()
            } else if let s = decoder.summary(summary) {
                list[id] = s
                await feeds[id]?.metadata(decoder.metadata(summary))
            }
            publishList()
        case "_acpmux/lagged":
            let ids = n.params["sessionIds"]?.arrayValue?.compactMap(\.stringValue)
            for (id, feed) in feeds where ids == nil || ids!.contains(id) {
                await feed.backfill()
            }
            if ids == nil || n.params["watch"]?.boolValue == true, let client {
                if let r = try? await client.request("_acpmux/sessions", .object([:])) {
                    list = [:]
                    for v in r["sessions"]?.arrayValue ?? [] {
                        if let s = decoder.summary(v) { list[s.id.rawValue] = s }
                    }
                    publishList()
                }
            }
        default:
            if let id = n.sessionID, let feed = feeds[id] {
                await feed.handle(n)
            }
        }
    }
}
