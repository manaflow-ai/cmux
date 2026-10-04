import Foundation
public import Observation

/// Why `perform` did not return a committed result.
public enum HomeSendState: Error, Hashable, Sendable {
    /// Sent, but the answer was lost; the store resends it with the same key
    /// (the owner applies it once). Do not send it again yourself.
    case pendingResend
}

/// The Home client: the confirmed mirror plus the intent log, fed by one
/// `HomeSource`. The UI reads `rows`, `transcript(for:)` and `connection`,
/// and changes things only through `perform(_:)`.
@MainActor
@Observable
public final class HomeStore {
    /// `.connecting` and `.offline` both refuse new ops (nothing queues).
    public private(set) var connection: HomeConnection = .connecting
    public private(set) var rows: [InboxRow] = []
    /// Increments whenever a transcript's visible items change.
    public private(set) var transcriptVersion: [ConversationID: Int] = [:]
    public private(set) var me: Participant?
    public private(set) var typing: [ConversationID: Set<ParticipantID>] = [:]

    @ObservationIgnored public let source: any HomeSource
    @ObservationIgnored private(set) var mirror = HomeMirror()
    @ObservationIgnored private(set) var log = IntentLog()
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var resendTask: Task<Void, Never>?
    @ObservationIgnored private var pendingResends: [HomeIntent] = []
    @ObservationIgnored private var refetching: Set<HomeStream> = []
    @ObservationIgnored private var olderLoading: Set<ConversationID> = []
    /// Views showing each conversation's transcript now (`open` minus `close`).
    @ObservationIgnored private var viewers: [ConversationID: Int] = [:]
    @ObservationIgnored private var stopped = false

    /// Messages fetched when a conversation opens.
    public static let tailSize = 60
    public static let pageSize = 80

    public init(source: any HomeSource) {
        self.source = source
    }

    /// Starts consuming owner events. Idempotent.
    public func start() {
        guard eventTask == nil, !stopped else { return }
        let source = self.source
        eventTask = Task { [weak self] in
            let stream = await source.events()
            for await event in stream {
                guard let self, !self.stopped else { return }
                self.handle(event)
            }
        }
    }

    /// Ends this store (sign-out, account switch). Every later op is refused.
    public func stop() {
        stopped = true
        eventTask?.cancel()
        eventTask = nil
        resendTask?.cancel()
        resendTask = nil
        connection = .offline(since: Date())
    }

    // MARK: Reading

    public var isOnline: Bool { connection == .online && !stopped }

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

    /// A view shows the conversation's transcript; each call pairs with one
    /// `close`. Loads the newest messages the first time it opens. Events
    /// committed while the page loads are buffered and kept.
    public func open(_ id: ConversationID) async {
        viewers[id, default: 0] += 1
        guard mirror.windows[id] == nil else { return }
        mirror.beginLoading(id)
        await refetch(.conversation(id))
    }

    /// A view of the conversation's transcript went away; pairs with one
    /// `open`. When the last one goes, the transcript is on screen nowhere:
    /// the store drops its window (the next `open` loads it again) and tells
    /// the source, which may end what it keeps for it (a cloud
    /// subscription, an archived conversation shown only while open).
    public func close(_ id: ConversationID) {
        guard let count = viewers[id] else { return }
        guard count <= 1 else {
            viewers[id] = count - 1
            return
        }
        viewers[id] = nil
        mirror.endTranscript(id)
        bumpTranscript(id)
        source.close(id)
    }

    public func loadOlder(_ id: ConversationID) async {
        guard let window = mirror.windows[id], !window.reachedStart, let first = window.firstSeq,
              !olderLoading.contains(id) else { return }
        olderLoading.insert(id)
        defer { olderLoading.remove(id) }
        guard let older = try? await source.history(of: id, before: first, limit: Self.pageSize) else { return }
        // The window may have been replaced during the await; a page that no
        // longer joins it is dropped (the next scroll asks again).
        guard mirror.windows[id]?.firstSeq == first else { return }
        if mirror.prepend(older, to: id, reachedStart: older.count < Self.pageSize) { bumpTranscript(id) }
    }

    // MARK: Writing

    /// Sends an intent to its owner. Refused at once unless online (nothing
    /// queues). Throws `HomeRejection` when refused, and
    /// `HomeSendState.pendingResend` when the answer was lost and the store
    /// resends it with the same key.
    @discardableResult
    public func perform(_ op: HomeOp, key: IdempotencyKey = .make()) async throws -> HomeOpResult {
        guard isOnline else { throw HomeRejection.ownerUnreachable }
        if case .setTyping = op {
            // Ephemeral: no intent, nothing to settle or resend.
            return try await source.submit(HomeIntent(key: key, op: op))
        }
        let intent = HomeIntent(key: key, op: op)
        guard log.append(intent) else { throw HomeRejection.invalid("duplicate intent") }
        afterLogChange(op)
        return try await submit(intent)
    }

    /// Retries a "Not Delivered" send as a new intent and drops the failed one.
    public func retry(_ key: IdempotencyKey) async throws {
        guard isOnline else { throw HomeRejection.ownerUnreachable }
        guard let entry = log.entries.first(where: { $0.intent.key == key }),
              case .failed = entry.state else { return }
        log.discard(key)
        afterLogChange(entry.intent.op)
        try await perform(entry.intent.op)
    }

    public func discardFailed(_ key: IdempotencyKey) {
        guard let entry = log.entries.first(where: { $0.intent.key == key }),
              case .failed = entry.state else { return }
        log.discard(key)
        afterLogChange(entry.intent.op)
    }

    /// Marks everything up to the newest message as read (once per seq:
    /// the visible cursor already includes a pending cursor intent).
    public func markRead(_ id: ConversationID) {
        guard isOnline, let me = me?.id, let summary = mirror.conversations[id] else { return }
        let visible = rows.first { $0.id == id }?.summary.readCursors[me] ?? summary.readCursors[me] ?? 0
        guard summary.lastSeq > visible else { return }
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
                // Possibly committed: keep it and resend with the same key.
                log.markUnconfirmed(intent.key)
                if isOnline, let again = log.takeImmediateResend(intent.key) { enqueueResends([again]) }
                afterLogChange(intent.op)
                throw HomeSendState.pendingResend
            default:
                if case .sendMessage = intent.op {
                    log.fail(intent.key, rejection)
                } else {
                    log.discard(intent.key)
                }
                afterLogChange(intent.op)
                throw rejection
            }
        }
    }

    /// Resends run one at a time, in log order, so the owner sees them in order.
    private func enqueueResends(_ intents: [HomeIntent]) {
        pendingResends.append(contentsOf: intents)
        guard resendTask == nil, !pendingResends.isEmpty else { return }
        resendTask = Task { [weak self] in
            while let self, !self.pendingResends.isEmpty, !self.stopped {
                let next = self.pendingResends.removeFirst()
                _ = try? await self.submit(next)
            }
            self?.resendTask = nil
        }
    }

    func handle(_ event: HomeEvent) {
        switch event {
        case .connection(let state):
            let wasOnline = connection == .online
            connection = state
            if state != .online {
                log.markDisconnected()
                pendingResends.removeAll()
            }
            if state == .online, !wasOnline {
                enqueueResends(log.takeResends())
                for stream in mirror.stale { scheduleRefetch(stream) }
            }
            rebuildRows()
        case .ownerRecovered:
            // Offline intents wait for the reconnect, which resends them anyway.
            guard isOnline else { return }
            enqueueResends(log.takeResends())
            for stream in mirror.stale { scheduleRefetch(stream) }
            rebuildRows()
        case .intentsRevoked(let keys):
            // A resend already queued must not go either; one in flight is refused by its owner.
            pendingResends.removeAll { keys.contains($0.key) }
            for op in log.revoke(keys) {
                if let id = op.conversation { bumpTranscript(id) }
            }
            rebuildRows()
        case .typing(let id, let who, let on):
            var set = typing[id] ?? []
            if on { set.insert(who) } else { set.remove(who) }
            typing[id] = set.isEmpty ? nil : set
            rebuildRows()
        default:
            let outcome = mirror.apply(event)
            switch event {
            case .inbox(let snapshot):
                me = snapshot.me
                log.dropIntents(outside: Set(mirror.conversations.keys))
                for stream in mirror.stale { scheduleRefetch(stream) }
            case .conversationRemoved:
                log.dropIntents(outside: Set(mirror.conversations.keys))
            case .message(let message, _):
                bumpTranscript(message.conversation)
            case .conversationPage(let page):
                bumpTranscript(page.conversation.id)
            default:
                break
            }
            settle()
            rebuildRows()
            if case .gap(let stream) = outcome { scheduleRefetch(stream) }
        }
    }

    private func scheduleRefetch(_ stream: HomeStream) {
        guard !refetching.contains(stream), !stopped else { return }
        Task { await self.refetch(stream) }
    }

    /// Fetches a stream until it is caught up (at most three tries per call).
    /// A failure leaves it stale; the next reconnect fetches it again.
    private func refetch(_ stream: HomeStream) async {
        guard !refetching.contains(stream), !stopped else { return }
        refetching.insert(stream)
        defer { refetching.remove(stream) }
        for _ in 0..<3 where !stopped {
            switch stream {
            case .inbox:
                guard let snapshot = try? await source.inbox() else { mirror.markStale(stream); return }
                let behind = mirror.apply(inbox: snapshot)
                me = snapshot.me
                settle()
                rebuildRows()
                for next in behind { scheduleRefetch(next) }
                return
            case .conversation(let id):
                guard let page = try? await source.snapshot(of: id, tail: Self.tailSize) else {
                    mirror.markStale(stream)
                    return
                }
                let outcome = mirror.apply(page: page)
                bumpTranscript(id)
                settle()
                rebuildRows()
                if outcome == .applied { return }
            }
        }
    }

    private func settle() {
        let settled = log.settle(against: mirror)
        guard !settled.isEmpty else { return }
        for id in Array(transcriptVersion.keys) { bumpTranscript(id) }
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
