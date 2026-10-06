import CmuxHomeCore
import CmuxNextDaemon
import Foundation
import Synchronization

/// The shared Home core's `HomeSource` over the local daemon's conversation
/// owner (`local-conversations-v1`, plans/cmux-next/home-mac.md 1). The owner
/// is the daemon; this adapter only reads its replies and events and sends
/// typed ops with the intent's idempotency key. `HomeService` feeds the
/// owner's events (side events and connection changes) through `publish`.
nonisolated final class DaemonHomeSource: HomeSource {
    private struct State {
        var continuations: [UUID: AsyncStream<HomeEvent>.Continuation] = [:]
        var connection: DaemonConnection?
        var lastEvent: [HomeEvent] = []
    }
    private let state = Mutex(State())
    /// Per subscriber. A subscriber that falls this far behind loses the
    /// oldest events; the store sees the revision gap and refetches.
    private static let eventBuffer = 1024

    /// The local user: the only `me` of the local owner.
    let me: Participant
    /// Fetched attachment variants, one file per hash and variant.
    let attachmentCache: URL
    /// Most bytes `attachmentCache` keeps; least recently used files go first.
    let attachmentCacheLimit: Int

    init(me: Participant, attachmentCache: URL = DaemonHomeSource.defaultAttachmentCache,
         attachmentCacheLimit: Int = DaemonHomeSource.defaultAttachmentCacheLimit) {
        self.me = me
        self.attachmentCache = attachmentCache
        self.attachmentCacheLimit = attachmentCacheLimit
    }

    // MARK: Fed by HomeService (main actor)

    /// A new connection (or none): the stream restarts with `.connection`
    /// and, when online, the full inbox.
    func connectionChanged(_ connection: DaemonConnection?) {
        state.withLock { $0.connection = connection }
        guard connection != nil else {
            publish(.connection(.offline(since: Date())))
            return
        }
        // task-owner: one inbox read per connection; ends with its reply
        Task { [weak self] in
            guard let self else { return }
            publish(.connection(.online))
            if let inbox = try? await inbox() { publish(.inbox(inbox)) }
        }
    }

    func publish(_ event: HomeEvent) {
        let targets = state.withLock { state -> [AsyncStream<HomeEvent>.Continuation] in
            if case .connection = event { state.lastEvent = [event] } else if case .inbox = event { state.lastEvent.append(event) }
            return Array(state.continuations.values)
        }
        for target in targets { target.yield(event) }
    }

    /// One owner event (`conversation-changed`) as Home core events.
    func publish(_ event: ConversationEvent, summary: CmuxNextDaemon.ConversationSummary?) {
        switch event.change {
        case .message(let message), .messageUpdated(let message):
            publish(.message(HomeCoreMapping.message(message), rev: event.rev))
        case .readCursor, .conversation, .unknown:
            break
        }
        if let summary {
            publish(.conversationChanged(HomeCoreMapping.summary(summary), stream: .conversation(ConversationID(summary.id)),
                                         rev: event.rev))
        }
    }

    // MARK: HomeSource

    func events() async -> AsyncStream<HomeEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<HomeEvent>.makeStream(bufferingPolicy: .bufferingNewest(Self.eventBuffer))
        let replay = state.withLock { state -> [HomeEvent] in
            state.continuations[id] = continuation
            return state.lastEvent
        }
        for event in replay.isEmpty ? [.connection(.connecting)] : replay { continuation.yield(event) }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            state.withLock { _ = $0.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    func requireConnection() throws -> DaemonConnection {
        guard let connection = state.withLock({ $0.connection }) else { throw HomeRejection.ownerUnreachable }
        return connection
    }

    func inbox() async throws -> InboxSnapshot {
        let list = try await Self.mapped { try await ConversationClient(self.requireConnection()).list() }
        let rev = list.map(\.rev).max() ?? 0
        return InboxSnapshot(me: me, conversations: list.map(HomeCoreMapping.summary), rev: rev)
    }

    func snapshot(of conversation: ConversationID, tail: Int) async throws -> ConversationPage {
        let page = try await Self.mapped {
            try await ConversationClient(self.requireConnection()).snapshot(conversation.rawValue, tail: min(max(tail, 1), 500))
        }
        return ConversationPage(conversation: HomeCoreMapping.summary(page.conversation),
                                messages: page.messages.map(HomeCoreMapping.message))
    }

    func history(of conversation: ConversationID, before beforeSeq: Seq, limit: Int) async throws -> [Message] {
        try await Self.mapped {
            try await ConversationClient(self.requireConnection())
                .history(conversation.rawValue, before: beforeSeq, limit: min(max(limit, 1), 500))
        }.map(HomeCoreMapping.message)
    }

    func submit(_ intent: HomeIntent) async throws -> HomeOpResult {
        // Typing is never stored: the owner's typing frame, not an op.
        if case .setTyping(let conversation, let on) = intent.op {
            try await Self.mapped {
                try await ConversationClient(self.requireConnection()).typing(conversation.rawValue, actor: me.id.rawValue, on: on)
            }
            return HomeOpResult(rev: 0, conversation: conversation)
        }
        guard let mapped = HomeCoreMapping.op(intent.op, key: intent.key) else {
            throw HomeRejection.invalid("unsupported_on_local_owner")
        }
        let request = ConversationOpRequest(conversation: mapped.conversation, idempotencyKey: intent.key.rawValue,
                                            transaction: ClientTransactionID(rawValue: intent.key.rawValue), op: mapped.op)
        let result = try await Self.mapped { try await ConversationClient(self.requireConnection()).op(request) }
        return HomeOpResult(rev: result.rev, replayed: result.replayed, conversation: ConversationID(mapped.conversation))
    }

    func search(_ query: String, limit: Int) async throws -> [HomeSearchHit] {
        let response = try await Self.mapped {
            try await self.requireConnection().request(ConversationSearchRequest(query: query, limit: min(max(limit, 1), 100)))
        }
        return response.hits.map { hit in
            let message = Message(id: MessageID(hit.messageID), conversation: ConversationID(hit.conversation), seq: hit.seq,
                                  clientMessageID: IdempotencyKey(hit.messageID), author: ParticipantID(hit.author),
                                  parts: [.text(hit.snippet)], createdAt: HomeCoreMapping.date(hit.createdAt) ?? .distantPast)
            return HomeSearchHit(conversation: ConversationID(hit.conversation), message: message, highlights: [])
        }
    }

    func resolve(_ contact: ContactAddress) async throws -> ContactResolution {
        // Invites need the cloud owner; the local owner only knows local participants.
        .invitable(contact)
    }

    /// The owner's refusals as `HomeRejection`: a reject is final, a lost
    /// connection leaves the outcome open (the store resends the same key).
    static func mapped<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let rejection as HomeRejection {
            throw rejection
        } catch DaemonError.command(_, let message, let code, _, _)
                    where code == "conversation_rejected" || code == "attachment_rejected" {
            throw HomeRejection.invalid(message)

        } catch DaemonError.notConnected {
            throw HomeRejection.ownerUnreachable
        } catch {
            throw HomeRejection.indeterminate
        }
    }
}
