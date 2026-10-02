public import Foundation

/// An in-memory owner for Home, used until the messaging backend lands and in
/// tests, previews and demos. It behaves like a real owner: it assigns seqs and
/// revisions, dedupes idempotency keys, publishes events after each commit,
/// refuses ops while offline, and lets Chiefs answer.
public actor MockHomeSource: HomeSource {
    public struct Options: Sendable {
        /// Messages in the Chief conversation (generated on demand, never all held).
        public var chiefHistory: Int
        /// Simulated owner latency for ops.
        public var latency: Duration
        /// Delay before a Chief starts typing and before it answers.
        public var replyDelay: Duration
        public var startsOnline: Bool

        public init(chiefHistory: Int = 2_000, latency: Duration = .milliseconds(120),
                    replyDelay: Duration = .milliseconds(900), startsOnline: Bool = true) {
            self.chiefHistory = chiefHistory
            self.latency = latency
            self.replyDelay = replyDelay
            self.startsOnline = startsOnline
        }

        /// No delays: for tests.
        public static let immediate = Options(chiefHistory: 300, latency: .zero, replyDelay: .zero)
    }

    private let options: Options
    private let clock: any Clock<Duration>
    private var online: Bool
    private var inboxRev: Revision = 1
    private var conversations: [ConversationID: ConversationSummary] = [:]
    /// Materialized messages; the generated Chief history before `generatedUpTo` is computed on read.
    private var stored: [ConversationID: [Message]] = [:]
    private var generated: [ConversationID: Seq] = [:]
    private var ledger: [IdempotencyKey: HomeOpResult] = [:]
    private var subscribers: [UUID: AsyncStream<HomeEvent>.Continuation] = [:]
    private var people: [ParticipantID: Participant] = [:]
    private var members: [ContactAddress: ParticipantID] = [:]
    private var nextID = 1

    public let me: Participant
    public let chief: Participant
    private let epoch: Date

    public init(options: Options = Options(), clock: any Clock<Duration> = ContinuousClock(), now: Date = Date()) {
        self.options = options
        self.clock = clock
        self.online = options.startsOnline
        self.epoch = now
        let seed = MockHomeSeed.make(now: now, chiefHistory: options.chiefHistory)
        self.me = seed.me
        self.chief = seed.chief
        for summary in seed.conversations { conversations[summary.id] = summary }
        stored = seed.messages
        generated = seed.generated
        for person in seed.people { people[person.id] = person }
        members = seed.members
    }

    // MARK: HomeSource

    public func events() -> AsyncStream<HomeEvent> {
        let (stream, continuation) = AsyncStream<HomeEvent>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        if online {
            continuation.yield(.connection(.online))
            continuation.yield(.inbox(inboxSnapshot()))
        } else {
            continuation.yield(.connection(.offline(since: Date())))
        }
        return stream
    }

    public func inbox() throws -> InboxSnapshot {
        guard online else { throw HomeRejection.ownerUnreachable }
        return inboxSnapshot()
    }

    public func snapshot(of conversation: ConversationID, tail: Int) throws -> ConversationPage {
        guard online else { throw HomeRejection.ownerUnreachable }
        guard let summary = conversations[conversation] else { throw HomeRejection.invalid("unknown_conversation") }
        let last = summary.lastSeq
        let first = last >= Seq(tail) ? last - Seq(tail) + 1 : 1
        return ConversationPage(conversation: summary, messages: messages(in: conversation, from: first, through: last))
    }

    public func history(of conversation: ConversationID, before beforeSeq: Seq, limit: Int) throws -> [Message] {
        guard online else { throw HomeRejection.ownerUnreachable }
        guard beforeSeq > 1 else { return [] }
        let last = beforeSeq - 1
        let first = last >= Seq(limit) ? last - Seq(limit) + 1 : 1
        return messages(in: conversation, from: first, through: last)
    }

    public func submit(_ intent: HomeIntent) async throws -> HomeOpResult {
        if options.latency > .zero { try? await clock.sleep(for: options.latency) }
        guard online else { throw HomeRejection.ownerUnreachable }
        if var replay = ledger[intent.key] {
            replay.replayed = true
            return replay
        }
        let result = try apply(intent)
        ledger[intent.key] = result
        if case .sendMessage(let conversation, _) = intent.op { scheduleReplies(in: conversation) }
        return result
    }

    public func search(_ query: String, limit: Int) throws -> [HomeSearchHit] {
        guard online else { throw HomeRejection.ownerUnreachable }
        let needle = query.lowercased()
        var hits: [HomeSearchHit] = []
        let ordered = conversations.values.sorted { $0.updatedAt > $1.updatedAt }
        for summary in ordered {
            let last = summary.lastSeq
            let first = last > 2_000 ? last - 1_999 : 1
            for message in messages(in: summary.id, from: first, through: last).reversed() {
                let text = message.plainText
                guard let range = text.lowercased().range(of: needle) else { continue }
                let start = text.utf16.distance(from: text.startIndex, to: range.lowerBound)
                let length = text.utf16.distance(from: range.lowerBound, to: range.upperBound)
                hits.append(HomeSearchHit(conversation: summary.id, message: message, highlights: [start..<(start + length)]))
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }

    public func resolve(_ contact: ContactAddress) throws -> ContactResolution {
        guard online else { throw HomeRejection.ownerUnreachable }
        if let id = members[contact], let person = people[id] { return .member(person) }
        return .invitable(contact)
    }

    // MARK: Test and demo controls

    /// Simulates losing or regaining the owners.
    public func setOnline(_ value: Bool) {
        guard value != online else { return }
        online = value
        if value {
            publish(.connection(.online))
            publish(.inbox(inboxSnapshot()))
        } else {
            publish(.connection(.offline(since: Date())))
        }
    }

    /// Posts a message as someone else (incoming traffic for demos).
    public func receive(_ text: String, from author: ParticipantID, in conversation: ConversationID) {
        _ = try? commitMessage(in: conversation, author: author, parts: [.text(text)], key: .make())
    }

    // MARK: Owner logic

    private func apply(_ intent: HomeIntent) throws -> HomeOpResult {
        switch intent.op {
        case .sendMessage(let conversation, let parts):
            let text = parts.map(\.plainText).joined()
            guard !text.isEmpty, text.utf8.count <= 65_536 else { throw HomeRejection.invalid("invalid_parts") }
            let rev = try commitMessage(in: conversation, author: me.id, parts: parts, key: intent.key)
            return HomeOpResult(rev: rev, conversation: conversation)
        case .setReadCursor(let conversation, let seq):
            guard var summary = conversations[conversation] else { throw HomeRejection.invalid("unknown_conversation") }
            let current = summary.readCursors[me.id] ?? 0
            guard seq <= summary.lastSeq else { throw HomeRejection.invalid("cursor_beyond_end") }
            guard seq > current else { return HomeOpResult(rev: summary.rev) }
            summary.readCursors[me.id] = seq
            summary.rev += 1
            conversations[conversation] = summary
            publish(.conversationChanged(summary, stream: .conversation(conversation), rev: summary.rev))
            return HomeOpResult(rev: summary.rev)
        case .setPinned(let conversation, let rank):
            return try updateInbox(conversation) { $0.pinRank = rank }
        case .setMuted(let conversation, let muted):
            return try updateInbox(conversation) { $0.muted = muted }
        case .createChief(let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 60 else { throw HomeRejection.invalid("invalid_name") }
            let agent = Participant(id: ParticipantID("agent_\(mintID())"), kind: .agent, displayName: trimmed,
                                    agentClass: .chief, ownerUser: me.id)
            people[agent.id] = agent
            let id = createConversation(title: "", participants: [me, agent])
            _ = try? commitMessage(in: id, author: agent.id, parts: [.text(MockHomeSeed.chiefGreeting(trimmed))], key: .make())
            return HomeOpResult(rev: inboxRev, conversation: id)
        case .createGroup(let title, let ids):
            let participants = [me] + ids.compactMap { people[$0] }
            guard participants.count >= 3 else { throw HomeRejection.invalid("group_needs_three") }
            let id = createConversation(title: title, participants: participants)
            return HomeOpResult(rev: inboxRev, conversation: id)
        case .startConversation(let contacts, let firstMessage):
            guard !contacts.isEmpty else { throw HomeRejection.invalid("no_recipients") }
            var participants = [me]
            var receipt: InviteReceipt?
            for contact in contacts {
                let (person, invite) = personFor(contact)
                participants.append(person)
                receipt = receipt ?? invite
            }
            let id = existingDirect(with: participants) ?? createConversation(title: "", participants: participants)
            if !firstMessage.isEmpty {
                _ = try? commitMessage(in: id, author: me.id, parts: firstMessage, key: intent.key)
            }
            return HomeOpResult(rev: inboxRev, conversation: id, invite: receipt)
        case .invite(let contact):
            // An invite changes no inbox entry, so the current revision settles it.
            let (_, receipt) = personFor(contact)
            return HomeOpResult(rev: inboxRev, invite: receipt ?? InviteReceipt(contact: contact, channel: contact.isEmail ? .email : .sms, alreadyMember: true))
        case .addReaction(let messageID, let conversation, let kind, let partIndex):
            guard var list = stored[conversation], let index = list.firstIndex(where: { $0.id == messageID }),
                  var summary = conversations[conversation] else { throw HomeRejection.invalid("unknown_message") }
            let reaction = Reaction(author: me.id, partIndex: partIndex, kind: kind)
            if !list[index].reactions.contains(reaction) { list[index].reactions.append(reaction) }
            stored[conversation] = list
            summary.rev += 1
            conversations[conversation] = summary
            publish(.message(list[index], rev: summary.rev))
            return HomeOpResult(rev: summary.rev)
        }
    }

    private func updateInbox(_ conversation: ConversationID, _ change: (inout ConversationSummary) -> Void) throws -> HomeOpResult {
        guard var summary = conversations[conversation] else { throw HomeRejection.invalid("unknown_conversation") }
        change(&summary)
        conversations[conversation] = summary
        inboxRev += 1
        publish(.conversationChanged(summary, stream: .inbox, rev: inboxRev))
        return HomeOpResult(rev: inboxRev)
    }

    @discardableResult
    private func commitMessage(in conversation: ConversationID, author: ParticipantID, parts: [MessagePart], key: IdempotencyKey) throws -> Revision {
        guard var summary = conversations[conversation] else { throw HomeRejection.invalid("unknown_conversation") }
        guard summary.participants.contains(where: { $0.id == author }) else { throw HomeRejection.notAuthorized }
        let message = Message(id: MessageID("msg_\(mintID())"), conversation: conversation, seq: summary.lastSeq + 1,
                              clientMessageID: key, author: author, parts: parts, createdAt: Date())
        stored[conversation, default: []].append(message)
        summary.lastSeq = message.seq
        summary.lastMessage = message
        summary.updatedAt = message.createdAt
        summary.rev += 1
        if author == me.id { summary.readCursors[me.id] = message.seq }
        conversations[conversation] = summary
        publish(.message(message, rev: summary.rev))
        return summary.rev
    }

    private func createConversation(title: String, participants: [Participant]) -> ConversationID {
        let id = ConversationID("conv_\(mintID())")
        let now = Date()
        let summary = ConversationSummary(id: id, title: title, participants: participants, createdAt: now, updatedAt: now)
        conversations[id] = summary
        inboxRev += 1
        publish(.conversationChanged(summary, stream: .inbox, rev: inboxRev))
        return id
    }

    private func existingDirect(with participants: [Participant]) -> ConversationID? {
        guard participants.count == 2 else { return nil }
        let wanted = Set(participants.map(\.id))
        return conversations.values.first { Set($0.participants.map(\.id)) == wanted && $0.title.isEmpty }?.id
    }

    private func personFor(_ contact: ContactAddress) -> (Participant, InviteReceipt?) {
        if let id = members[contact], let person = people[id] { return (person, nil) }
        let person = Participant(id: ParticipantID("user_inv_\(mintID())"), kind: .human, displayName: contact.description,
                                 membership: .invited, invitedContact: contact.description)
        people[person.id] = person
        members[contact] = person.id
        return (person, InviteReceipt(contact: contact, channel: contact.isEmail ? .email : .sms, alreadyMember: false))
    }

    private func scheduleReplies(in conversation: ConversationID) {
        guard let summary = conversations[conversation] else { return }
        let chiefs = summary.participants.filter(\.isChief)
        // In groups a Chief answers only when mentioned (multi-party rule); the mock answers with the first Chief.
        guard let responder = chiefs.first else { return }
        let delay = options.replyDelay
        let clock = self.clock
        Task {
            if delay > .zero { try? await clock.sleep(for: delay) }
            self.typing(responder.id, in: conversation, on: true)
            if delay > .zero { try? await clock.sleep(for: delay) }
            self.reply(as: responder, in: conversation)
        }
    }

    private func typing(_ who: ParticipantID, in conversation: ConversationID, on: Bool) {
        publish(.typing(conversation, who, on: on))
    }

    private func reply(as responder: Participant, in conversation: ConversationID) {
        publish(.typing(conversation, responder.id, on: false))
        let count = stored[conversation]?.count ?? 0
        _ = try? commitMessage(in: conversation, author: responder.id,
                               parts: [.text(MockHomeSeed.reply(index: count))], key: .make())
    }

    private func messages(in conversation: ConversationID, from first: Seq, through last: Seq) -> [Message] {
        guard first <= last, let summary = conversations[conversation] else { return [] }
        let generatedUpTo = generated[conversation] ?? 0
        var result: [Message] = []
        result.reserveCapacity(Int(last - first + 1))
        if first <= generatedUpTo {
            for seq in first...min(last, generatedUpTo) {
                result.append(MockHomeSeed.generatedMessage(seq: seq, total: generatedUpTo, in: summary, epoch: epoch))
            }
        }
        if last > generatedUpTo {
            let lower = max(first, generatedUpTo + 1)
            result.append(contentsOf: (stored[conversation] ?? []).filter { $0.seq >= lower && $0.seq <= last })
        }
        return result
    }

    private func inboxSnapshot() -> InboxSnapshot {
        InboxSnapshot(me: me, conversations: Array(conversations.values), rev: inboxRev)
    }

    private func publish(_ event: HomeEvent) {
        for continuation in subscribers.values { continuation.yield(event) }
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    private func mintID() -> String {
        defer { nextID += 1 }
        return String(format: "mock%06d", nextID)
    }
}
