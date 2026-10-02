import Foundation
public import Observation

/// The Home client: the confirmed mirror plus the intent log, fed by one
/// `HomeSource`. The UI reads `rows`, `transcript(for:)` and `connection`,
/// and changes things only through `perform(_:)`.
@MainActor
@Observable
public final class HomeStore {
    public private(set) var connection: HomeConnection = .connecting
    public private(set) var rows: [InboxRow] = []
    /// Increments whenever any transcript's visible items change.
    public private(set) var transcriptVersion: [ConversationID: Int] = [:]
    public private(set) var me: Participant?
    public private(set) var typing: [ConversationID: Set<ParticipantID>] = [:]

    @ObservationIgnored public let source: any HomeSource
    @ObservationIgnored private(set) var mirror = HomeMirror()
    @ObservationIgnored private(set) var log = IntentLog()
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var loading: Set<ConversationID> = []

    /// Messages fetched when a conversation opens.
    public static let tailSize = 60
    public static let pageSize = 80

    public init(source: any HomeSource) {
        self.source = source
    }

    // `isolated deinit` needs Swift 6.2; the owner calls `stop()` instead.

    /// Starts consuming owner events. Idempotent.
    public func start() {
        guard eventTask == nil else { return }
        let source = self.source
        eventTask = Task { [weak self] in
            let stream = await source.events()
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    public func stop() {
        eventTask?.cancel()
        eventTask = nil
    }

    // MARK: Reading

    public var isOnline: Bool { connection == .online }

    public func summary(_ id: ConversationID) -> ConversationSummary? { mirror.conversations[id] }

    public func transcript(for id: ConversationID) -> [TranscriptItem] {
        guard let me = me?.id else { return [] }
        return (mirror.windows[id] ?? TranscriptWindow()).items(pending: log.sends(in: id), me: me)
    }

    public func hasOlderMessages(in id: ConversationID) -> Bool {
        guard let window = mirror.windows[id] else { return false }
        return !window.reachedStart
    }

    public func participant(_ id: ParticipantID, in conversation: ConversationID) -> Participant? {
        if id == me?.id { return me }
        return mirror.conversations[conversation]?.participants.first { $0.id == id }
    }

    // MARK: Paging

    /// Loads the newest messages of a conversation the first time it opens.
    public func open(_ id: ConversationID) async {
        guard mirror.windows[id] == nil, !loading.contains(id) else { return }
        await refetch(.conversation(id))
    }

    public func loadOlder(_ id: ConversationID) async {
        guard let window = mirror.windows[id], !window.reachedStart, let first = window.firstSeq,
              !loading.contains(id) else { return }
        loading.insert(id)
        defer { loading.remove(id) }
        do {
            let older = try await source.history(of: id, before: first, limit: Self.pageSize)
            mirror.prepend(older, to: id, reachedStart: older.count < Self.pageSize)
            bumpTranscript(id)
        } catch {
            // A failed page leaves the window as it was; the next scroll retries.
        }
    }

    // MARK: Writing

    /// Sends an intent to its owner. Refused at once while offline (nothing
    /// queues). Sends stay in the transcript until echoed or refused.
    @discardableResult
    public func perform(_ op: HomeOp, key: IdempotencyKey = .make()) async throws -> HomeOpResult {
        guard isOnline else { throw HomeRejection.ownerUnreachable }
        let intent = HomeIntent(key: key, op: op)
        guard log.append(intent) else { throw HomeRejection.invalid("duplicate intent") }
        afterLogChange(op)
        return try await submit(intent)
    }

    /// Retries a "Not Delivered" send as a new intent and drops the failed one.
    public func retry(_ key: IdempotencyKey) async throws {
        guard let entry = log.entries.first(where: { $0.intent.key == key }) else { return }
        log.discard(key)
        afterLogChange(entry.intent.op)
        try await perform(entry.intent.op)
    }

    public func discardFailed(_ key: IdempotencyKey) {
        guard let entry = log.entries.first(where: { $0.intent.key == key }) else { return }
        log.discard(key)
        afterLogChange(entry.intent.op)
    }

    /// Marks everything up to the newest message as read.
    public func markRead(_ id: ConversationID) {
        guard isOnline, let me = me?.id, let summary = mirror.conversations[id],
              summary.unreadCount(me: me) > 0 else { return }
        Task { try? await self.perform(.setReadCursor(conversation: id, seq: summary.lastSeq)) }
    }

    public func search(_ query: String, limit: Int = 50) async throws -> [HomeSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try await source.search(trimmed, limit: limit)
    }

    public func resolve(_ contact: ContactAddress) async throws -> ContactResolution {
        try await source.resolve(contact)
    }

    // MARK: Internals

    private func submit(_ intent: HomeIntent) async throws -> HomeOpResult {
        do {
            let result = try await source.submit(intent)
            log.acknowledge(intent.key, rev: result.rev)
            settle()
            afterLogChange(intent.op)
            return result
        } catch let rejection as HomeRejection {
            switch rejection {
            case .ownerUnreachable, .indeterminate:
                // Sent but unanswered: resent with the same key on reconnect.
                log.markDisconnected()
            default:
                if case .sendMessage = intent.op {
                    log.fail(intent.key, rejection)
                } else {
                    log.discard(intent.key)
                }
            }
            afterLogChange(intent.op)
            throw rejection
        }
    }

    func handle(_ event: HomeEvent) async {
        switch event {
        case .connection(let state):
            let wasOnline = isOnline
            connection = state
            if case .offline = state { log.markDisconnected(); rebuildRows() }
            if state == .online, !wasOnline {
                for intent in log.takeResends() {
                    Task { _ = try? await self.submit(intent) }
                }
            }
        case .typing(let id, let who, let on):
            var set = typing[id] ?? []
            if on { set.insert(who) } else { set.remove(who) }
            typing[id] = set.isEmpty ? nil : set
            rebuildRows()
        default:
            let outcome = mirror.apply(event)
            if case .inbox(let snapshot) = event { me = snapshot.me }
            settle()
            rebuildRows()
            if case .message(let message, _) = event { bumpTranscript(message.conversation) }
            if case .gap(let stream) = outcome { await refetch(stream) }
        }
    }

    private func refetch(_ stream: HomeStream) async {
        switch stream {
        case .inbox:
            if let snapshot = try? await source.inbox() {
                mirror.apply(inbox: snapshot)
                me = snapshot.me
            }
        case .conversation(let id):
            loading.insert(id)
            defer { loading.remove(id) }
            if let page = try? await source.snapshot(of: id, tail: Self.tailSize) {
                mirror.apply(page: page)
                bumpTranscript(id)
            }
        }
        settle()
        rebuildRows()
    }

    private func settle() {
        let settled = log.settle(against: mirror)
        if !settled.isEmpty { transcriptVersion = transcriptVersion.mapValues { $0 + 1 } }
    }

    private func afterLogChange(_ op: HomeOp) {
        rebuildRows()
        if let id = op.conversation { bumpTranscript(id) }
    }

    private func bumpTranscript(_ id: ConversationID) {
        transcriptVersion[id, default: 0] += 1
    }

    private func rebuildRows() {
        rows = mirror.inboxRows(log: log, typing: Set(typing.keys))
    }
}
