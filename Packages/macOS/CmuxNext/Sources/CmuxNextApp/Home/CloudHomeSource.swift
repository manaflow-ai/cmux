import CmuxHomeCore
import CmuxNextDaemon
import Foundation
import Synchronization

/// The shared Home core's `HomeSource` over the cloud owners, reached only
/// through the local daemon's proxy (`cloud-conversations-v1`,
/// plans/cmux-next/home-cloud-proxy.md). ConversationDO owns each
/// conversation and UserDO owns the inbox; this adapter reads their replies
/// and events and sends typed ops with the intent's key. It never talks to
/// the Worker itself and never derives an id.
///
/// What it keeps is a projection, not a second owner: the inbox entries the
/// daemon listed or pushed, and the newest head it saw per conversation, so
/// a conversation's summary carries both the owner's head (participants,
/// cursors, last message) and the inbox's pin and mute. The inbox does not
/// carry participant names, so a listed conversation without a head reads
/// a one-message snapshot once (`hydrate`).
nonisolated final class CloudHomeSource: HomeSource {
    /// A subscribed conversation and the last state its socket reported.
    struct Target: Hashable, Sendable {
        var state: String
        /// An event set `state`; the subscribe reply no longer may.
        var fromEvent = false
    }

    private struct State {
        var continuations: [UUID: AsyncStream<HomeEvent>.Continuation] = [:]
        var lastEvent: [HomeEvent] = []
        var commands: (any CloudConversationCommands)?
        var link: ObjectIdentifier?
        var identity: CloudIdentity?
        /// Bumps on every configure; work started under an older one is dropped.
        var generation: UInt64 = 0
        var entries: [ConversationID: CloudInboxEntry] = [:]
        var heads: [ConversationID: CmuxHomeCore.ConversationSummary] = [:]
        var targets: [ConversationID: Target] = [:]
        /// Subscribed conversations, least recently used first.
        var recent: [ConversationID] = []
        var hydrating: Set<ConversationID> = []
        /// This source's inbox stream revision: one per inbox event it publishes.
        var inboxRev: Revision = 0
    }

    private let state = Mutex(State())
    private static let eventBuffer = 1024
    static let inboxLimit = CloudInboxListRequest.maxLimit
    static let hydrationWidth = 4
    /// The local user's participant in this store (`CloudIdentity.localID`).
    let me: Participant

    init(me: Participant) {
        self.me = me
    }

    // MARK: Fed by HomeService

    /// A daemon connection with the cloud transport (or none, `link` names
    /// it) and the signed-in account (or none). A new account, or signing
    /// out, empties the cloud part of the inbox; a lost connection only goes
    /// offline and keeps what this source knew.
    func configure(commands: (any CloudConversationCommands)?, link: ObjectIdentifier?, identity: CloudIdentity?) {
        let change = state.withLock { state -> (generation: UInt64, cleared: Bool, ended: [ConversationID], kept: [ConversationID],
                                                old: (any CloudConversationCommands)?)? in
            guard link != state.link || identity != state.identity else { return nil }
            let cleared = identity != state.identity
            // The same connection keeps the old account's interests: end them.
            let ended = cleared && link == state.link ? Array(state.targets.keys) : []
            // The same account on a new connection: its open conversations subscribe again.
            let kept = cleared ? [] : state.recent
            let old = state.commands
            state.generation += 1
            state.commands = commands
            state.link = link
            state.identity = identity
            // Without a connection the open conversations are remembered for the next one.
            if commands != nil || cleared {
                state.targets = [:]
                state.recent = []
            }
            state.hydrating = []
            if cleared {
                state.entries = [:]
                state.heads = [:]
            }
            return (state.generation, cleared, ended, kept, old)
        }
        guard let change else { return }
        if let old = change.old, !change.ended.isEmpty {
            let ended = change.ended
            // task-owner: ends the previous account's subscriptions; ends with the replies
            Task { for id in ended { _ = try? await old.unsubscribe(id.rawValue) } }
        }
        if change.cleared { publishInbox() }
        guard let commands, identity != nil else {
            publish(.connection(.offline(since: Date())))
            return
        }
        publish(.connection(.online))
        let generation = change.generation
        let kept = change.kept
        // task-owner: one inbox subscribe and list, then the kept conversations' subscribes; ends with their replies
        Task { [weak self] in
            _ = try? await commands.subscribeInbox()
            await self?.reloadInbox(generation: generation)
            for id in kept { await self?.subscribe(id, commands: commands, generation: generation) }
        }
    }

    /// One `cloud-*` event from the daemon. Lease requests go to the lease, not here.
    func handle(_ event: CloudConversationsEvent) {
        switch event {
        case .changed(let changed): apply(changed)
        case .resynced(let resynced): apply(resynced)
        case .inboxChanged(let changed): apply(changed)
        case .inboxReset:
            let generation = state.withLock { $0.generation }
            // task-owner: one inbox list; ends with its reply
            Task { [weak self] in await self?.reloadInbox(generation: generation) }
        case .subscriptionState(let report): apply(report)
        case .sessionNeeded:
            break
        }
    }

    // MARK: HomeSource

    func events() async -> AsyncStream<HomeEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<HomeEvent>.makeStream(bufferingPolicy: .bufferingNewest(Self.eventBuffer))
        state.withLock { state in
            state.continuations[id] = continuation
            for event in state.lastEvent.isEmpty ? [.connection(.connecting)] : state.lastEvent { continuation.yield(event) }
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    /// The cloud inbox; empty while signed out or without the transport.
    func inbox() async throws -> InboxSnapshot {
        let (commands, identity, generation) = state.withLock { ($0.commands, $0.identity, $0.generation) }
        guard let commands, identity != nil else { return state.withLock { snapshot(&$0) } }
        let list = try await Self.mapped { try await commands.inboxList(limit: Self.inboxLimit) }
        let (inbox, missing) = state.withLock { state -> (InboxSnapshot, [ConversationID]) in
            guard state.generation == generation else { return (snapshot(&state), []) }
            state.entries = Dictionary(list.entries.filter(\.isListed).map { (ConversationID($0.conversation), $0) },
                                       uniquingKeysWith: { $1 })
            return (snapshot(&state), needsHead(state))
        }
        hydrate(missing, generation: generation)
        return inbox
    }

    /// The cloud part of the inbox as this source knows it now (no read).
    func currentInbox() -> InboxSnapshot { state.withLock { snapshot(&$0) } }

    func snapshot(of conversation: ConversationID, tail: Int) async throws -> ConversationPage {
        let (commands, identity, generation) = try requireEndpoint()
        await subscribe(conversation, commands: commands, generation: generation)
        let page = try await Self.mapped { try await commands.snapshot(conversation.rawValue, tail: tail) }
        let summary = CloudHomeMapping.summary(page.conversation, identity: identity)
        return state.withLock { state in
            if state.generation == generation { state.heads[conversation] = summary }
            return ConversationPage(conversation: joined(conversation, state) ?? summary,
                                    messages: page.messages.map { CloudHomeMapping.message($0, identity: identity) })
        }
    }

    func history(of conversation: ConversationID, before beforeSeq: Seq, limit: Int) async throws -> [Message] {
        let (commands, identity, _) = try requireEndpoint()
        let page = try await Self.mapped { try await commands.history(conversation.rawValue, before: beforeSeq, limit: limit) }
        return page.messages.map { CloudHomeMapping.message($0, identity: identity) }
    }

    func submit(_ intent: HomeIntent) async throws -> HomeOpResult {
        let (commands, identity, generation) = try requireEndpoint()
        let key = intent.key.rawValue
        func send(_ op: CloudConversationOp, in conversation: ConversationID?, key: String = key) async throws -> CloudConversationOpResult {
            let request = CloudConversationOpRequest(conversation: conversation?.rawValue, idempotencyKey: key, origin: "user", op: op)
            return try await Self.mapped { try await commands.op(request) }
        }
        func edit(_ op: CloudConversationOp, in conversation: ConversationID) async throws -> HomeOpResult {
            try requireEditable(conversation, commands: commands, generation: generation)
            let result = try await send(op, in: conversation)
            return HomeOpResult(rev: result.rev ?? 0, replayed: result.replayed, conversation: conversation)
        }
        switch intent.op {
        case .sendMessage(let conversation, let parts):
            // The owner's message.send key must equal client_msg_id.
            return try await edit(.send(clientMsgID: key, parts: CloudHomeMapping.parts(parts, identity: identity), replyTo: nil),
                                  in: conversation)
        case .setReadCursor(let conversation, let seq):
            return try await edit(.setReadCursor(seq: seq), in: conversation)
        case .addReaction(let message, let conversation, let reaction, let partIndex):
            return try await edit(.addReaction(messageID: message.rawValue, partIndex: partIndex,
                                               kind: CloudHomeMapping.reaction(reaction)), in: conversation)
        case .setTyping(let conversation, _):
            // Typing is not in cloud-conversations-v1 part 1; nothing to send.
            return HomeOpResult(rev: 0, conversation: conversation)
        case .setPinned, .setMuted, .createChief:
            // inbox.pin, inbox.mute and chief.create are not cloud-conversation-op kinds yet
            // (home-cloud-proxy.md section 8); refused here exactly as the daemon would.
            throw HomeRejection.invalid("unsupported_op")
        case .createGroup(let title, let ids):
            let participants = [identity.participant] + state.withLock { state in
                ids.filter { $0 != identity.localID }.map { participantRecord($0, identity: identity, state) }
            }
            let result = try await send(.create(title: title.isEmpty ? nil : title, participants: participants), in: nil)
            let created = try opened(result, identity: identity, generation: generation)
            return HomeOpResult(rev: 0, replayed: result.replayed, conversation: created)
        case .invite(let contact):
            return try await openDM(with: contact, firstMessage: [], key: key, identity: identity, generation: generation, send: send)
        case .startConversation(let contacts, let firstMessage):
            guard let first = contacts.first else { throw HomeRejection.invalid("invalid_participant") }
            guard contacts.count > 1 else {
                return try await openDM(with: first, firstMessage: firstMessage, key: key, identity: identity,
                                        generation: generation, send: send)
            }
            // A group of addresses: create it with the user, then invite each address.
            let result = try await send(.create(title: nil, participants: [identity.participant]), in: nil)
            let created = try opened(result, identity: identity, generation: generation)
            for (index, contact) in contacts.enumerated() {
                _ = try await send(.createInvite(address: CloudHomeMapping.address(contact), displayName: Self.masked(contact), locale: nil),
                                   in: created, key: "\(key):invite:\(index)")
            }
            try await sendFirst(firstMessage, in: created, key: key, identity: identity, send: send)
            return HomeOpResult(rev: 0, replayed: result.replayed, conversation: created,
                                invite: InviteReceipt(contact: first, channel: first.isEmail ? .email : .sms, alreadyMember: false))
        }
    }

    /// Home search is not in cloud-conversations-v1 part 1.
    func search(_ query: String, limit: Int) async throws -> [HomeSearchHit] { [] }

    /// `dm.open` resolves addresses on the owner and answers the same whether
    /// or not the address has an account, so the client cannot tell.
    func resolve(_ contact: ContactAddress) async throws -> ContactResolution { .invitable(contact) }

    // MARK: Ops

    private func openDM(with contact: ContactAddress, firstMessage: [MessagePart], key: String, identity: CloudIdentity,
                        generation: UInt64,
                        send: (CloudConversationOp, ConversationID?, String) async throws -> CloudConversationOpResult) async throws -> HomeOpResult {
        let result = try await send(.dmOpen(peer: .address(CloudHomeMapping.address(contact))), nil, key)
        let conversation = try opened(result, identity: identity, generation: generation)
        try await sendFirst(firstMessage, in: conversation, key: key, identity: identity, send: send)
        let invited = result.invite?.ok == true
        return HomeOpResult(rev: 0, replayed: result.replayed, conversation: conversation,
                            invite: invited ? InviteReceipt(contact: contact, channel: contact.isEmail ? .email : .sms, alreadyMember: false) : nil)
    }

    /// The first message of a new conversation, keyed from the intent so a resend replays it.
    private func sendFirst(_ parts: [MessagePart], in conversation: ConversationID, key: String, identity: CloudIdentity,
                           send: (CloudConversationOp, ConversationID?, String) async throws -> CloudConversationOpResult) async throws {
        guard !parts.isEmpty else { return }
        let messageKey = "\(key):message"
        _ = try await send(.send(clientMsgID: messageKey, parts: CloudHomeMapping.parts(parts, identity: identity), replyTo: nil),
                           conversation, messageKey)
    }

    /// The conversation a `dm.open` or `conversation.create` answered, published at once.
    private func opened(_ result: CloudConversationOpResult, identity: CloudIdentity, generation: UInt64) throws -> ConversationID {
        guard let wire = result.conversation else { throw HomeRejection.indeterminate }
        let summary = CloudHomeMapping.summary(wire, identity: identity)
        publish(generation: generation) { state in
            state.heads[summary.id] = summary
            state.inboxRev += 1
            return .conversationChanged(joined(summary.id, state) ?? summary, stream: .inbox, rev: state.inboxRev)
        }
        return summary.id
    }

    /// The masked form the Worker shows for an address (home-core `maskAddress`).
    static func masked(_ contact: ContactAddress) -> String {
        switch contact {
        case .email(let value):
            let pieces = value.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { return "***" }
            return "\(pieces[0].prefix(1))***@\(pieces[1])"
        case .phone(let value):
            let digits = value.dropFirst()
            return "+\(digits.dropLast(10)) *** *** \(value.suffix(4))"
        }
    }

    // MARK: Events

    private func apply(_ changed: CloudConversationChanged) {
        let id = ConversationID(changed.conversation)
        publish { state in
            guard let identity = state.identity else { return nil }
            switch changed.change {
            case .message(let wire), .messageUpdated(let wire):
                let message = CloudHomeMapping.message(wire, identity: identity)
                if var head = state.heads[id] {
                    if message.seq >= head.lastSeq {
                        head.lastSeq = message.seq
                        head.lastMessage = message
                        head.updatedAt = max(head.updatedAt, message.createdAt)
                    }
                    head.rev = max(head.rev, changed.rev)
                    state.heads[id] = head
                }
                return .message(message, rev: changed.rev)
            case .readCursor(let participant, let seq):
                guard var head = state.heads[id] else { return nil }
                let reader = identity.toHome(participant)
                head.readCursors[reader] = max(head.readCursors[reader] ?? 0, seq)
                head.rev = max(head.rev, changed.rev)
                state.heads[id] = head
            case .conversation(let wire):
                state.heads[id] = CloudHomeMapping.summary(wire, identity: identity)
            case .unknown:
                // An invite delivery report: no Home field changes, but the revision moves.
                guard var head = state.heads[id] else { return nil }
                head.rev = max(head.rev, changed.rev)
                state.heads[id] = head
            }
            guard let summary = joined(id, state) else { return nil }
            return .conversationChanged(summary, stream: .conversation(id), rev: changed.rev)
        }
    }

    private func apply(_ resynced: CloudConversationResynced) {
        let id = ConversationID(resynced.conversation)
        publish { state in
            guard let identity = state.identity else { return nil }
            let summary = CloudHomeMapping.summary(resynced.summary, identity: identity)
            state.heads[id] = summary
            return .conversationPage(ConversationPage(conversation: joined(id, state) ?? summary,
                                                      messages: resynced.messages.map { CloudHomeMapping.message($0, identity: identity) }))
        }
    }

    private func apply(_ changed: CloudInboxChanged) {
        var missing: [ConversationID] = []
        var generation: UInt64 = 0
        for entry in changed.entries {
            let id = ConversationID(entry.conversation)
            publish { state in
                guard state.identity != nil else { return nil }
                generation = state.generation
                state.inboxRev += 1
                guard entry.isListed else {
                    state.entries[id] = nil
                    if state.targets[id] == nil { state.heads[id] = nil }
                    return .conversationRemoved(id, inboxRev: state.inboxRev)
                }
                state.entries[id] = entry
                if needsHead(id, state) { missing.append(id) }
                return joined(id, state).map { .conversationChanged($0, stream: .inbox, rev: state.inboxRev) }
            }
        }
        hydrate(missing, generation: generation)
    }

    private func apply(_ report: CloudSubscriptionState) {
        guard report.scope == "conversation", let conversation = report.conversation else { return }
        let id = ConversationID(conversation)
        state.withLock { state in
            guard state.targets[id] != nil else { return }
            if report.state == "closed" {
                // Forbidden: the user is no longer a participant. The inbox removes it.
                state.targets[id] = nil
                state.recent.removeAll { $0 == id }
            } else {
                state.targets[id] = Target(state: report.state, fromEvent: true)
            }
        }
    }

    // MARK: Subscriptions

    private enum SubscribeStep {
        case skip
        case start(evicted: ConversationID?)
    }

    /// Subscribes once per conversation; the least recently used of 64 makes room.
    private func subscribe(_ conversation: ConversationID, commands: any CloudConversationCommands, generation: UInt64) async {
        let step = state.withLock { state -> SubscribeStep in
            guard state.generation == generation else { return .skip }
            if state.targets[conversation] != nil {
                state.recent.removeAll { $0 == conversation }
                state.recent.append(conversation)
                return .skip
            }
            var evicted: ConversationID?
            if state.recent.count >= CloudConversationSubscribeRequest.maxSubscriptions {
                let oldest = state.recent.removeFirst()
                state.targets[oldest] = nil
                evicted = oldest
            }
            state.targets[conversation] = Target(state: "connecting")
            state.recent.append(conversation)
            return .start(evicted: evicted)
        }
        guard case .start(let evicted) = step else { return }
        if let evicted { _ = try? await commands.unsubscribe(evicted.rawValue) }
        do {
            let reply = try await commands.subscribe(conversation.rawValue)
            state.withLock { state in
                guard state.generation == generation, state.targets[conversation]?.fromEvent == false else { return }
                state.targets[conversation]?.state = reply.state
            }
        } catch {
            state.withLock { state in
                guard state.generation == generation, state.targets[conversation]?.fromEvent == false else { return }
                state.targets[conversation] = nil
                state.recent.removeAll { $0 == conversation }
            }
        }
    }

    /// Refuses an edit while the conversation's socket reports it disconnected
    /// or closed (home-cloud-proxy.md section 5). A conversation without a
    /// subscription is subscribed so its echo can settle the intent.
    private func requireEditable(_ conversation: ConversationID, commands: any CloudConversationCommands, generation: UInt64) throws {
        let target = state.withLock { $0.targets[conversation] }
        guard let target else {
            // task-owner: one subscribe; ends with its reply
            Task { [weak self] in await self?.subscribe(conversation, commands: commands, generation: generation) }
            return
        }
        if target.state == "disconnected" || target.state == "closed" { throw HomeRejection.invalid("cloud_not_live") }
    }

    // MARK: Inbox

    private func reloadInbox(generation: UInt64) async {
        guard state.withLock({ $0.generation == generation }), let inbox = try? await inbox() else { return }
        publish(generation: generation) { _ in .inbox(inbox) }
    }

    private func publishInbox() {
        publish { state in .inbox(snapshot(&state)) }
    }

    /// Reads a one-message snapshot for each listed conversation without a
    /// current head, a few at a time, and publishes its summary.
    private func hydrate(_ ids: [ConversationID], generation: UInt64) {
        let (commands, identity, fresh) = state.withLock { state -> ((any CloudConversationCommands)?, CloudIdentity?, [ConversationID]) in
            guard state.generation == generation else { return (nil, nil, []) }
            let fresh = ids.filter { !state.hydrating.contains($0) }
            state.hydrating.formUnion(fresh)
            return (state.commands, state.identity, fresh)
        }
        guard let commands, let identity, !fresh.isEmpty else { return }
        // task-owner: one bounded batch of snapshot reads; ends when the batch does
        Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                var pending = fresh[...]
                for _ in 0..<Self.hydrationWidth {
                    guard let id = pending.popFirst() else { break }
                    group.addTask { await self.hydrateOne(id, commands: commands, identity: identity, generation: generation) }
                }
                while await group.next() != nil {
                    guard let id = pending.popFirst() else { continue }
                    group.addTask { await self.hydrateOne(id, commands: commands, identity: identity, generation: generation) }
                }
            }
        }
    }

    private func hydrateOne(_ id: ConversationID, commands: any CloudConversationCommands, identity: CloudIdentity,
                            generation: UInt64) async {
        let page = try? await commands.snapshot(id.rawValue, tail: 1)
        publish(generation: generation) { state in
            state.hydrating.remove(id)
            guard let page, state.entries[id] != nil else { return nil }
            let summary = CloudHomeMapping.summary(page.conversation, identity: identity)
            if let known = state.heads[id], known.rev >= summary.rev { return nil }
            state.heads[id] = summary
            state.inboxRev += 1
            return joined(id, state).map { .conversationChanged($0, stream: .inbox, rev: state.inboxRev) }
        }
    }

    // MARK: State helpers (call with the lock held)

    private func snapshot(_ state: inout State) -> InboxSnapshot {
        state.inboxRev += 1
        let conversations = state.entries.keys.compactMap { joined($0, state) }
        return InboxSnapshot(me: me, conversations: conversations, rev: state.inboxRev)
    }

    /// The head with the inbox's pin and mute, or the entry alone.
    private func joined(_ id: ConversationID, _ state: State) -> CmuxHomeCore.ConversationSummary? {
        guard let identity = state.identity else { return nil }
        let entry = state.entries[id]
        guard var summary = state.heads[id] else { return entry.map { CloudHomeMapping.summary($0, identity: identity) } }
        if let entry { CloudHomeMapping.apply(entry, to: &summary) }
        return summary
    }

    /// A listed conversation whose head is missing or older than its entry,
    /// unless its socket keeps the head current.
    private func needsHead(_ id: ConversationID, _ state: State) -> Bool {
        guard let entry = state.entries[id], state.targets[id] == nil else { return false }
        guard let head = state.heads[id] else { return true }
        return entry.rev > head.rev
    }

    private func needsHead(_ state: State) -> [ConversationID] {
        state.entries.keys.filter { needsHead($0, state) }.sorted { $0.rawValue < $1.rawValue }
    }

    /// A participant for `conversation.create`, as a known head names it.
    private func participantRecord(_ id: ParticipantID, identity: CloudIdentity, _ state: State) -> ConversationParticipant {
        let known = state.heads.values.lazy.flatMap(\.participants).first { $0.id == id }
        let wireID = identity.toCloud(id)
        let isAgent = known.map { $0.kind == .agent } ?? wireID.hasPrefix("agent_")
        return ConversationParticipant(id: wireID, kind: isAgent ? .agent : .human, displayName: known?.displayName ?? wireID,
                                       agentClass: isAgent ? (known?.agentClass == .chief ? "mux" : "agent") : nil)
    }

    private func requireEndpoint() throws -> (any CloudConversationCommands, CloudIdentity, UInt64) {
        let (commands, identity, generation) = state.withLock { ($0.commands, $0.identity, $0.generation) }
        guard let identity else { throw HomeRejection.notAuthorized }
        guard let commands else { throw HomeRejection.ownerUnreachable }
        return (commands, identity, generation)
    }

    // MARK: Publishing

    private func publish(_ event: HomeEvent) {
        publish { _ in event }
    }

    /// Builds and yields one event under the lock, so revisions reach every
    /// subscriber in the order they were assigned.
    private func publish(generation: UInt64? = nil, _ build: (inout State) -> HomeEvent?) {
        state.withLock { state in
            if let generation, state.generation != generation { return }
            guard let event = build(&state) else { return }
            switch event {
            case .connection: state.lastEvent = [event]
            case .inbox: state.lastEvent = state.lastEvent.filter { if case .connection = $0 { true } else { false } } + [event]
            default: break
            }
            for continuation in state.continuations.values { continuation.yield(event) }
        }
    }

    /// The daemon's answers as `HomeRejection` (home-cloud-proxy.md section 6).
    static func mapped<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let rejection as HomeRejection {
            throw rejection
        } catch let error as DaemonError {
            throw rejection(error)
        } catch {
            throw HomeRejection.indeterminate
        }
    }

    static func rejection(_ error: DaemonError) -> HomeRejection {
        switch error {
        case .command(_, let message, let code, _, let retryable):
            let reason = error.rejectReason ?? message
            switch code {
            case "cloud_conversation_rejected":
                if retryable == true { return .rateLimited(retryAfter: nil) }
                return reason == "forbidden" ? .notAuthorized : .invalid(reason)
            case "cloud_signed_out": return .notAuthorized
            // Refused before the owner saw it: nothing committed; resent after a new lease.
            case "cloud_session_expired", "cloud_unauthenticated": return .ownerUnreachable
            // The outcome of a mutation is unknown: resend with the same key.
            case "cloud_unavailable": return .indeterminate
            default: return .invalid(reason)
            }
        case .notConnected, .missingCapabilities: return .ownerUnreachable
        default: return .indeterminate
        }
    }
}
