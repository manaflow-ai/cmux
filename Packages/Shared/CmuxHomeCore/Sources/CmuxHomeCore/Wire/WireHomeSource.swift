public import Foundation

/// A ``HomeSource`` that speaks the hosted `cmux.wire/1` protocol directly
/// (plans/cmux-next/dm-group-chat-DESIGN.md sections 4.3 and 4.5): the iOS
/// app's DMs and group chats, against the cmux cloud (``HomeWireAuth/stack(_:)``)
/// or a self-hosted `cmux-chat-server` on the user's tailnet
/// (``HomeWireAuth/tailscale``). It does what the macOS daemon's cloud proxy
/// does (cmux-tui-cloud-conversations), without the daemon:
///
/// - Ops go to `POST /v1/ops {op, params, idempotency_key, origin}` with the
///   intent's key (for `message.send` also its `client_msg_id`), so a resend
///   of the same intent is a replay on the owner, never a second message.
/// - Reads go to `POST /v1/read {op, params}` (`inbox.list`,
///   `conversation.snapshot`, `conversation.history`, `conversation.thread`,
///   `home.search`).
/// - The inbox streams over `/v1/wire/user`; a conversation on screen streams
///   over `/v1/wire/conv/<id>` from its first ``snapshot(of:tail:)`` until
///   ``close(_:)``. Both resume with `after_seq` and repair gaps by snapshot
///   (``HomeWireStream``).
///
/// What it keeps is a projection, not a second owner: the inbox entries and
/// the newest head per conversation, so a summary carries both the head
/// (participants, cursors, last message) and the entry (pin, mute). The
/// store keeps the mirror and the intent log; this source never retries an
/// op by itself.
///
/// ```swift
/// let url = try HomeChatServer.selfHostedURL("mini.tail1234.ts.net")
/// let source = WireHomeSource(baseURL: url, auth: .tailscale, transport: URLSessionHomeWireTransport())
/// let store = HomeStore(source: source)
/// store.start()
/// ```
///
/// Tests pass a fake ``HomeWireHTTP`` and ``HomeWireSocketConnecting`` and a
/// manual clock (the backoff between dials runs on it).
public actor WireHomeSource: HomeSource {
    static let inboxLimit = 200
    /// Pages of `inboxLimit` entries one inbox read follows at most.
    static let inboxPages = 50
    static let hydrationWidth = 4
    static let eventBuffer = 1024

    let client: HomeWireClient
    let sockets: any HomeWireSocketConnecting
    let clock: any Clock<Duration>
    let mapping = HomeWireMapping()
    /// Where fetched attachment bytes are kept, by hash and variant.
    let fetchDirectory: URL
    /// The user's name until the owner names them (the hosted welcome names only the id).
    let displayName: String

    /// The signed-in user as the server knows them; nil until the server said who.
    var me: Participant?
    var connection: HomeConnection = .connecting
    var continuations: [UUID: AsyncStream<HomeEvent>.Continuation] = [:]
    /// Listed inbox entries (the owner's rows), by conversation.
    var entries: [ConversationID: HomeWireJSON] = [:]
    /// The newest head seen per conversation.
    var heads: [ConversationID: ConversationSummary] = [:]
    /// Conversations this client created or opened that the inbox does not list yet.
    var created: Set<ConversationID> = []
    /// The inbox revision this source publishes (one per inbox change it sends).
    var inboxRev: Revision = 0
    var inboxLoaded = false
    var userStream: HomeWireStream?
    var conversationStreams: [ConversationID: HomeWireStream] = [:]
    /// Who typed in a conversation on its current socket (off when it drops).
    var typists: [ConversationID: Set<ParticipantID>] = [:]
    var hydrating: Set<ConversationID> = []
    var bootTask: Task<Void, Never>?
    var stopped = false

    /// - Parameters:
    ///   - baseURL: The server (`https://…` hosted; `http://<host>.ts.net:7320` self-hosted).
    ///   - auth: Bearer for the cmux cloud, nothing for a tailnet server.
    ///   - displayName: The user's name until the owner names them.
    ///   - http: Every HTTP exchange (the fake in tests).
    ///   - sockets: Every WebSocket (the fake in tests).
    ///   - clock: Paces the backoff between dials and the keepalive pings.
    ///   - fetchDirectory: Where fetched attachments are written.
    public init(baseURL: URL, auth: HomeWireAuth, displayName: String = "", http: any HomeWireHTTP,
                sockets: any HomeWireSocketConnecting, clock: any Clock<Duration> = ContinuousClock(),
                fetchDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-home-wire", isDirectory: true)) {
        client = HomeWireClient(baseURL: baseURL, auth: auth, http: http)
        self.sockets = sockets
        self.clock = clock
        self.displayName = displayName
        self.fetchDirectory = fetchDirectory
    }

    /// The production source over one URLSession transport.
    public init(baseURL: URL, auth: HomeWireAuth, displayName: String = "",
                transport: URLSessionHomeWireTransport = URLSessionHomeWireTransport()) {
        self.init(baseURL: baseURL, auth: auth, displayName: displayName, http: transport, sockets: transport)
    }

    /// Ends every socket and every event stream (a sign-out, or another
    /// server chosen in Settings). The source does nothing after this.
    public func shutdown() async {
        stopped = true
        bootTask?.cancel()
        await userStream?.stop()
        userStream = nil
        for stream in conversationStreams.values { await stream.stop() }
        conversationStreams = [:]
        for continuation in continuations.values { continuation.finish() }
        continuations = [:]
    }

    /// Dials every stream that waits between dials now (the app came to the
    /// foreground, or the network came back).
    public func reconnectNow() async {
        await userStream?.reconnectNow()
        for stream in conversationStreams.values { await stream.reconnectNow() }
    }

    // MARK: HomeSource reads

    public func events() async -> AsyncStream<HomeEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<HomeEvent>.makeStream(bufferingPolicy: .bufferingNewest(Self.eventBuffer))
        guard !stopped else {
            continuation.finish()
            return stream
        }
        continuations[id] = continuation
        continuation.yield(.connection(connection))
        if inboxLoaded, let me { continuation.yield(.inbox(inboxSnapshot(me: me))) }
        continuation.onTermination = { [weak self] _ in
            // task-owner: one removal; ends at once
            Task { await self?.removeContinuation(id) }
        }
        start()
        return stream
    }

    public func inbox() async throws -> InboxSnapshot {
        try await loadInbox()
    }

    public func snapshot(of conversation: ConversationID, tail: Int) async throws -> ConversationPage {
        try Self.requireConversationID(conversation)
        guard me != nil else { throw HomeRejection.ownerUnreachable }
        openStream(conversation)
        let value = try await client.read("conversation.snapshot",
                                          ["conversation": .string(conversation.rawValue), "tail": .number(Double(min(50, max(1, tail))))])
        guard var page = mapping.page(value) else { throw HomeRejection.invalid("unknown_conversation") }
        heads[conversation] = page.conversation
        page.conversation = joined(conversation) ?? page.conversation
        return page
    }

    public func history(of conversation: ConversationID, before beforeSeq: Seq, limit: Int) async throws -> [Message] {
        try await historyPage(of: conversation, before: beforeSeq, limit: limit).messages
    }

    public func historyPage(of conversation: ConversationID, before beforeSeq: Seq, limit: Int) async throws -> HistoryPage {
        try Self.requireConversationID(conversation)
        let value = try await client.read("conversation.history", [
            "conversation": .string(conversation.rawValue), "before_seq": .uint(beforeSeq),
            "limit": .number(Double(min(200, max(1, limit)))),
        ])
        let messages = (value["messages"].array ?? []).compactMap(mapping.message).sorted { $0.seq < $1.seq }
        return HistoryPage(messages: messages, threads: (value["threads"].array ?? []).compactMap(mapping.threadSummary))
    }

    public func thread(of conversation: ConversationID, root: MessageID, after afterSeq: Seq, limit: Int) async throws -> ThreadPage {
        try Self.requireConversationID(conversation)
        let value: HomeWireJSON
        do {
            value = try await client.read("conversation.thread", [
                "conversation": .string(conversation.rawValue), "root": .string(root.rawValue),
                "after_seq": .uint(afterSeq), "limit": .number(Double(min(200, max(1, limit)))),
            ])
        } catch HomeRejection.invalid {
            // An owner without thread reads (an older self-hosted server): scan history.
            return try await scanThread(of: conversation, root: root, after: afterSeq, limit: limit)
        }
        guard let rootMessage = mapping.message(value["root"]) else { throw HomeRejection.invalid("unknown_message") }
        let replies = (value["replies"].array ?? []).compactMap(mapping.message).sorted { $0.seq < $1.seq }
        var stats = value["thread"]
        if stats.object != nil, stats["root"].isNull, case .object(var fields) = stats {
            fields["root"] = .string(root.rawValue)
            stats = .object(fields)
        }
        let summary = mapping.threadSummary(stats) ?? ThreadSummary(root: root, replies: replies)
        return ThreadPage(root: rootMessage, replies: replies, hasMore: value["has_more"].bool ?? false, summary: summary)
    }

    /// `home.search` (hosted only; a self-hosted server has no search in v1
    /// and the client then shows local results only).
    public func search(_ query: String, limit: Int) async throws -> [HomeSearchHit] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let value: HomeWireJSON
        do {
            value = try await client.read("home.search", ["q": .string(String(text.prefix(200))),
                                                          "limit": .number(Double(min(100, max(1, limit))))])
        } catch HomeRejection.invalid {
            return []
        }
        return (value["hits"].array ?? []).compactMap { hit -> HomeSearchHit? in
            guard let conversation = hit["conversation"].string, let id = hit["message_id"].string,
                  let seq = hit["seq"].uint, let author = hit["author"].string else { return nil }
            let snippet = hit["snippet"].string ?? ""
            let message = Message(id: MessageID(id), conversation: ConversationID(conversation), seq: seq,
                                  clientMessageID: IdempotencyKey(id), author: ParticipantID(author),
                                  parts: [.text(snippet, mentions: [])],
                                  createdAt: mapping.date(hit["created_at"]) ?? .distantPast)
            let ranges = (hit["ranges"].array ?? []).compactMap { range -> Range<Int>? in
                guard let start = range["start"].int, let length = range["length"].int, length > 0 else { return nil }
                return Self.utf16Range(in: snippet, characterStart: start, length: length)
            }
            return HomeSearchHit(conversation: ConversationID(conversation), message: message, highlights: ranges)
        }
    }

    /// `dm.open` resolves an address on the owner and answers the same with
    /// or without an account behind it, so the client cannot tell.
    public func resolve(_ contact: ContactAddress) async throws -> ContactResolution { .invitable(contact) }

    /// The hosted owner takes `link_preview` parts.
    public func acceptsLinkPreviews(in conversation: ConversationID) async -> Bool { true }

    public nonisolated func close(_ conversation: ConversationID) {
        // task-owner: one stream stop; ends with it
        Task { await self.closeStream(conversation) }
    }

    // MARK: Lifecycle

    private func start() {
        guard bootTask == nil, !stopped else { return }
        bootTask = Task { await self.boot() }
    }

    private func boot() async {
        if case .tailscale = client.auth {
            // The server knows the caller by Tailscale; it says who that is.
            var attempt = 0
            while !stopped, !Task.isCancelled, me == nil {
                do {
                    let info = try await client.selfHostInfo()
                    me = Participant(id: ParticipantID(info.userID), kind: .human,
                                     displayName: info.displayName.isEmpty ? displayName : info.displayName)
                } catch {
                    setConnection(.offline(since: Date()))
                    // A bounded, cancellable retry delay (the server is down or Tailscale is off).
                    do { try await clock.sleep(for: reconnectDelay(attempt: attempt)) } catch { return }
                    attempt += 1
                }
            }
        }
        guard !stopped, !Task.isCancelled else { return }
        let stream = HomeWireStream(target: .inbox, client: client, sockets: sockets, clock: clock)
        userStream = stream
        consume(stream)
        await stream.start()
    }

    /// The conversation's stream, started once while it is on screen.
    func openStream(_ conversation: ConversationID) {
        guard !stopped, conversationStreams[conversation] == nil else { return }
        let stream = HomeWireStream(target: .conversation(conversation), client: client, sockets: sockets, clock: clock)
        conversationStreams[conversation] = stream
        consume(stream)
        // task-owner: one start; ends at once
        Task { await stream.start() }
    }

    private func closeStream(_ conversation: ConversationID) async {
        guard let stream = conversationStreams.removeValue(forKey: conversation) else { return }
        endTyping(in: conversation)
        await stream.stop()
        // Opened from a link or a notification and not listed: it leaves the inbox again.
        if entries[conversation] == nil, !created.contains(conversation), heads.removeValue(forKey: conversation) != nil {
            inboxRev += 1
            publish(.conversationRemoved(conversation, inboxRev: inboxRev))
        }
    }

    private func consume(_ stream: HomeWireStream) {
        let target = stream.target
        let events = stream.events
        // task-owner: drains one stream's events; ends when the stream stops
        Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event, from: target, stream: stream)
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    // MARK: Publishing

    func publish(_ event: HomeEvent) {
        for continuation in continuations.values { continuation.yield(event) }
    }

    func setConnection(_ next: HomeConnection) {
        switch (connection, next) {
        case (.offline, .offline): return
        default: break
        }
        guard connection != next else { return }
        connection = next
        publish(.connection(next))
    }

    /// A conversation's summary as the store shows it: the head with the
    /// entry's pin, mute and unread over it.
    func joined(_ conversation: ConversationID) -> ConversationSummary? {
        guard let me else { return heads[conversation] }
        guard var summary = heads[conversation] ?? entries[conversation].flatMap({ mapping.summary(entry: $0, me: me) }) else {
            return nil
        }
        if let entry = entries[conversation] { mapping.apply(entry: entry, to: &summary) }
        return summary
    }

    func inboxSnapshot(me: Participant) -> InboxSnapshot {
        let ids = Set(entries.keys).union(created)
        let conversations = ids.compactMap(joined).sorted { $0.updatedAt > $1.updatedAt }
        return InboxSnapshot(me: me, conversations: conversations, rev: inboxRev)
    }

    // MARK: Inbox

    /// Reads every page of `inbox.list`, publishes the whole inbox, and reads the heads it lacks.
    @discardableResult
    func loadInbox() async throws -> InboxSnapshot {
        guard let me else { throw HomeRejection.ownerUnreachable }
        // Every page, not the newest 200: the owner pages by keyset (`next_cursor`). An entry a later
        // page lists again (its activity moved it during the read) keeps the first page's copy.
        var next: [ConversationID: HomeWireJSON] = [:]
        var cursor: String?
        for _ in 0..<Self.inboxPages {
            var params: [String: HomeWireJSON] = ["limit": .number(Double(Self.inboxLimit))]
            if let cursor { params["cursor"] = .string(cursor) }
            // Any page's failure is the read's: `entries` is replaced as a whole, so a partial list
            // would drop every conversation past it.
            let value = try await client.read("inbox.list", .object(params))
            guard let rows = value["entries"].array else { throw HomeRejection.ownerUnreachable }
            for entry in rows where mapping.isListed(entry) {
                if let id = entry["conversation"].string, next[ConversationID(id)] == nil { next[ConversationID(id)] = entry }
            }
            // A cursor that does not move would read the same page again.
            guard let following = value["next_cursor"].string, following != cursor else { break }
            cursor = following
        }
        entries = next
        created.subtract(next.keys)
        // Heads of conversations that left the inbox go, unless one is on screen.
        heads = heads.filter { next[$0.key] != nil || created.contains($0.key) || conversationStreams[$0.key] != nil }
        inboxRev += 1
        inboxLoaded = true
        let snapshot = inboxSnapshot(me: me)
        setConnection(.online)
        publish(.inbox(snapshot))
        hydrate(next.keys.filter { id in heads[id] == nil || (heads[id]?.lastSeq ?? 0) < (next[id]?["last_seq"].uint ?? 0) })
        return snapshot
    }

    /// Reads a one-message snapshot of each conversation whose head this
    /// source lacks (an inbox entry has no participant names) or whose last
    /// message is older than its entry, a few at a time.
    func hydrate(_ conversations: [ConversationID]) {
        let due = conversations.filter { !hydrating.contains($0) && conversationStreams[$0] == nil }
        guard !due.isEmpty else { return }
        hydrating.formUnion(due)
        let client = self.client
        let mapping = self.mapping
        // task-owner: bounded snapshot reads; ends with their replies
        Task { [weak self] in
            await withTaskGroup(of: (ConversationID, ConversationSummary?).self) { group in
                var pending = due[...]
                func next() {
                    guard let id = pending.popFirst() else { return }
                    group.addTask {
                        let value = try? await client.read("conversation.snapshot", ["conversation": .string(id.rawValue), "tail": 1])
                        return (id, value.flatMap(mapping.page)?.conversation)
                    }
                }
                for _ in 0..<Self.hydrationWidth { next() }
                for await (id, summary) in group {
                    await self?.hydrated(id, summary)
                    next()
                }
            }
        }
    }

    private func hydrated(_ conversation: ConversationID, _ summary: ConversationSummary?) {
        hydrating.remove(conversation)
        guard let summary, !stopped, entries[conversation] != nil || created.contains(conversation) else { return }
        if let known = heads[conversation], known.rev > summary.rev { return }
        heads[conversation] = summary
        guard let joined = joined(conversation) else { return }
        inboxRev += 1
        publish(.conversationChanged(joined, stream: .inbox, rev: inboxRev))
    }

    // MARK: Ids

    /// A conversation id as the Worker writes it (`conv_` or `conv_dm_` and
    /// 26 Crockford base32 characters): checked before it enters a URL path.
    static func isConversationID(_ id: ConversationID) -> Bool {
        let raw = id.rawValue
        let suffix: Substring
        if raw.hasPrefix("conv_dm_") { suffix = raw.dropFirst(8) } else if raw.hasPrefix("conv_") { suffix = raw.dropFirst(5) } else { return false }
        return suffix.count == 26 && suffix.allSatisfy { ch in
            ch.isASCII && (ch.isNumber || (ch.isUppercase && !"ILOU".contains(ch)))
        }
    }

    static func requireConversationID(_ id: ConversationID) throws {
        guard isConversationID(id) else { throw HomeRejection.invalid("unknown_conversation") }
    }

    /// The UTF-16 range of `length` characters from character `start` of `text`.
    static func utf16Range(in text: String, characterStart start: Int, length: Int) -> Range<Int>? {
        guard start >= 0, start + length <= text.count else { return nil }
        let lower = text.index(text.startIndex, offsetBy: start)
        let upper = text.index(lower, offsetBy: length)
        let from = text.utf16.distance(from: text.utf16.startIndex, to: lower)
        return from..<(from + text.utf16.distance(from: lower, to: upper))
    }
}
