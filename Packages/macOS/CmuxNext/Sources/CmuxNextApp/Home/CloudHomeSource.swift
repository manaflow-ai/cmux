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
        /// The daemon holds a lease for `identity`. Until it does, no op goes
        /// out (they wait, `ownerUnreachable`) and nothing recovers.
        var leased = false
        /// Asks the link for a lease when an op or read found none.
        var leaseMissing: (@Sendable () -> Void)?
        /// Bumps on every configure; work started under an older one is dropped.
        var generation: UInt64 = 0
        var entries: [ConversationID: CloudInboxEntry] = [:]
        /// The inbox stream seq of the newest inbox event per conversation.
        /// An inbox list reply at an older revision keeps these
        /// conversations as the events left them. Emptied when the account
        /// changes and on an inbox reset (a new seq sequence).
        var touched: [ConversationID: UInt64] = [:]
        /// Conversations this source created (`dm.open`, `conversation.create`)
        /// whose UserDO entry has not arrived yet. Listed until it does.
        var created: Set<ConversationID> = []
        /// Conversations UserDO took out of the inbox (archived, left). Their
        /// stream events are dropped, so a late cursor, title or resync never
        /// lists them again; the user opening one again clears it.
        var removed: Set<ConversationID> = []
        var heads: [ConversationID: CmuxHomeCore.ConversationSummary] = [:]
        var targets: [ConversationID: Target] = [:]
        /// Subscribed conversations, least recently used first.
        var recent: [ConversationID] = []
        /// Conversations queued for or in a hydration read.
        var hydrating: Set<ConversationID> = []
        /// Hydration reads waiting for a worker, oldest first; at most
        /// `hydrationWidth` workers read at once for the whole source.
        var hydrationQueue: [ConversationID] = []
        var hydrationWorkers = 0
        /// Keys of intents this account submitted that are not known to be
        /// committed: the store may still resend them (or show a failed send).
        var accepted: Set<String> = []
        /// Keys of intents a previous account submitted. Refused for good, so
        /// none goes out under another identity (the owner scopes keys per actor).
        var revoked: Set<String> = []
        /// The unsubscribes sent so far, in order. A subscribe waits for them,
        /// so a late unsubscribe never ends a subscription made after it.
        var unsubscribing: Task<Void, Never>?
        /// This source's inbox stream revision: one per inbox event it publishes.
        var inboxRev: Revision = 0
        /// A read or op failed in a way that leaves intents unconfirmed; the
        /// next sign that the cloud is reachable publishes `.ownerRecovered`.
        var degraded = false
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
    /// it) and the account the daemon's lease is for (or none). `leased`
    /// is false while the daemon holds no lease for `identity` yet
    /// (`HomeCloudLink`): ops wait until `leaseRenewed(subject:)` names it.
    /// Everything this source keeps belongs to one account (its cloud id): a
    /// new account, or signing out, revokes the previous account's intents
    /// (`.intentsRevoked`, before any other event, and refused here for
    /// good) and empties the cloud part of the inbox. A lost connection only
    /// goes offline and keeps what this source knew; a new display name is
    /// the same account.
    func configure(commands: (any CloudConversationCommands)?, link: ObjectIdentifier?, identity: CloudIdentity?,
                   leased: Bool = true) {
        let same = state.withLock { state -> (renamed: Bool, nowLeased: Bool, generation: UInt64)? in
            guard link == state.link, let identity, let current = state.identity, current.cloudID == identity.cloudID,
                  current != identity || state.leased != leased else { return nil }
            defer {
                state.identity = identity
                state.leased = leased
            }
            return (current != identity, leased && !state.leased, state.generation)
        }
        if let same {
            if same.renamed { publishInbox() }
            if same.nowLeased { leaseArrived(generation: same.generation) }
            return
        }
        let change = state.withLock { state -> (generation: UInt64, cleared: Bool, kept: [ConversationID])? in
            guard link != state.link || identity != state.identity else { return nil }
            let cleared = identity?.cloudID != state.identity?.cloudID
            if cleared {
                // Under the same lock as the identity change, so no reply for the
                // new account can recover the store before it drops these.
                let revoked = Set(state.accepted.map { IdempotencyKey($0) })
                state.revoked.formUnion(state.accepted)
                state.accepted = []
                // Nothing of the new account waits to be resent.
                state.degraded = false
                if !revoked.isEmpty {
                    for continuation in state.continuations.values { continuation.yield(.intentsRevoked(revoked)) }
                }
            }
            // The same connection keeps the old account's interests: end them.
            let ended = cleared && link == state.link ? Array(state.targets.keys) : []
            // The same account on a new connection: its open conversations subscribe again.
            let kept = cleared ? [] : state.recent
            if let old = state.commands, !ended.isEmpty {
                // The previous account's subscriptions end before the next one subscribes.
                Self.chainUnsubscribes(ended, commands: old, &state)
            }
            state.generation += 1
            state.commands = commands
            state.link = link
            state.identity = identity
            state.leased = leased
            // Without a connection the open conversations are remembered for the next one.
            if commands != nil || cleared {
                state.targets = [:]
                state.recent = []
            }
            state.hydrating = []
            state.hydrationQueue = []
            state.hydrationWorkers = 0
            if cleared {
                state.entries = [:]
                state.touched = [:]
                state.created = []
                state.removed = []
                state.heads = [:]
            }
            return (state.generation, cleared, kept)
        }
        guard let change else { return }
        if change.cleared { publishInbox() }
        guard let commands, identity != nil else {
            publish(.connection(.offline(since: Date())))
            return
        }
        publish(.connection(.online))
        // The same account on a new connection: intents refused while there
        // was no transport resend after the first reply.
        if !change.cleared { state.withLock { $0.degraded = true } }
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
        guard isForThisAccount(event) else { return }
        switch event {
        case .changed(let changed): apply(changed)
        case .resynced(let resynced): apply(resynced)
        case .inboxChanged(let changed): apply(changed)
        case .inboxReset:
            let generation = state.withLock { state in
                state.touched = [:]
                return state.generation
            }
            // task-owner: one inbox list; ends with its reply
            Task { [weak self] in await self?.reloadInbox(generation: generation) }
        case .subscriptionState(let report): apply(report)
        case .sessionNeeded:
            break
        }
        // An owner event proves the cloud reachable again.
        if case .changed = event { recover() }
        if case .resynced = event { recover() }
        if case .inboxChanged = event { recover() }
    }

    /// Called (off any lock) when an op or read is refused because the
    /// daemon holds no lease for this account: nothing reaches the daemon
    /// then, so the daemon never asks for one itself.
    func onLeaseMissing(_ action: @escaping @Sendable () -> Void) {
        state.withLock { $0.leaseMissing = action }
    }

    /// A new display name for the account this source acts as; any other
    /// account changes nothing (that is a `configure`).
    func rename(_ identity: CloudIdentity) {
        let renamed = state.withLock { state -> Bool in
            guard let current = state.identity, current.cloudID == identity.cloudID, current != identity else { return false }
            state.identity = identity
            return true
        }
        if renamed { publishInbox() }
    }

    /// An owner event that names its account (the lease's `sub`) belongs to
    /// this source only when that is the account it acts as: another one's
    /// is a late event from before a switch, and is dropped. An event that
    /// names none (an older daemon) is kept.
    private func isForThisAccount(_ event: CloudConversationsEvent) -> Bool {
        let account: String? = switch event {
        case .changed(let changed): changed.account
        case .resynced(let resynced): resynced.account
        case .inboxChanged(let changed): changed.account
        default: nil
        }
        guard let account else { return true }
        return state.withLock { $0.identity?.cloudID } == CloudIdentity.cloudID(stackUserID: account)
    }

    /// The account this source acts as (its cloud id), leased or not.
    var accountID: String? { state.withLock { $0.identity?.cloudID } }

    /// The daemon took a new lease for `subject` (a Stack user id). Only a
    /// lease for the account this source acts as counts: refused ops can go
    /// through again, and an account that waited for its first lease lists
    /// its inbox. A lease for another account changes nothing here.
    func leaseRenewed(subject: String) {
        let renewed = state.withLock { state -> (first: Bool, generation: UInt64)? in
            guard let identity = state.identity, identity.cloudID == CloudIdentity.cloudID(stackUserID: subject) else { return nil }
            defer { state.leased = true }
            return (!state.leased, state.generation)
        }
        guard let renewed else { return }
        if renewed.first {
            leaseArrived(generation: renewed.generation)
        } else {
            recover()
        }
    }

    /// The first lease of this generation's account: what waited for it goes again.
    private func leaseArrived(generation: UInt64) {
        recover()
        // task-owner: one inbox list; ends with its reply
        Task { [weak self] in await self?.reloadInbox(generation: generation) }
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
            // Never take the state lock here: the stream may run this under its
            // own lock while `publish` yields under the state lock (a deadlock).
            // task-owner: one removal; ends at once
            Task { [weak self] in self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) } }
        }
        return stream
    }

    /// The cloud inbox; empty while signed out or without the transport.
    /// Without the lease it reads nothing (the daemon may still hold the
    /// previous account's) and answers what this source knows.
    func inbox() async throws -> InboxSnapshot {
        let (commands, identity, generation, leased) = state.withLock { ($0.commands, $0.identity, $0.generation, $0.leased) }
        guard let commands, let identity, leased else { return state.withLock { snapshot(&$0) } }
        let list = try await reply(for: identity) { try await commands.inboxList(limit: Self.inboxLimit) }
        let (inbox, missing, unlisted, current) = state.withLock { state -> (InboxSnapshot, [ConversationID], [ConversationID],
                                                                             (any CloudConversationCommands)?) in
            guard state.generation == generation else { return (snapshot(&state), [], [], nil) }
            var entries = Dictionary(list.entries.filter(\.isListed).map { (ConversationID($0.conversation), $0) },
                                     uniquingKeysWith: { $1 })
            if let revision = Self.revision(list.revision) {
                // An inbox event newer than this reply wins: its entry, or its absence.
                for (id, seq) in state.touched where seq > revision { entries[id] = state.entries[id] }
                state.touched = state.touched.filter { $0.value > revision }
            }
            state.created.subtract(entries.keys)
            state.removed.subtract(entries.keys)
            let gone = state.entries.keys.filter { entries[$0] == nil && !state.created.contains($0) }
            state.removed.formUnion(gone)
            state.entries = entries
            let unlisted = gone.filter { forget($0, &state) }
            return (snapshot(&state), needsHead(state), unlisted, state.commands)
        }
        unsubscribe(unlisted, commands: current)
        hydrate(missing, generation: generation)
        return inbox
    }

    #if DEBUG
    /// Conversations queued for or in a hydration read (tests).
    var queuedHydrations: Int { state.withLock { $0.hydrating.count } }
    #endif

    /// The cloud part of the inbox as this source knows it now (no read).
    func currentInbox() -> InboxSnapshot { state.withLock { snapshot(&$0) } }

    func snapshot(of conversation: ConversationID, tail: Int) async throws -> ConversationPage {
        let (commands, identity, generation) = try requireEndpoint()
        await subscribe(conversation, commands: commands, generation: generation)
        let page = try await reply(for: identity) { try await commands.snapshot(conversation.rawValue, tail: tail) }
        let summary = CloudHomeMapping.summary(page.conversation, identity: identity)
        return state.withLock { state in
            if state.generation == generation {
                state.heads[conversation] = summary
                // The user opened it: its stream may show it again.
                state.removed.remove(conversation)
            }
            return ConversationPage(conversation: joined(conversation, state) ?? summary,
                                    messages: page.messages.map { CloudHomeMapping.message($0, identity: identity) })
        }
    }

    func history(of conversation: ConversationID, before beforeSeq: Seq, limit: Int) async throws -> [Message] {
        let (commands, identity, _) = try requireEndpoint()
        let page = try await reply(for: identity) { try await commands.history(conversation.rawValue, before: beforeSeq, limit: limit) }
        return page.messages.map { CloudHomeMapping.message($0, identity: identity) }
    }

    /// Binds the intent's key to the signed-in account first: a key a
    /// previous account submitted is refused (`notAuthorized`, the store
    /// drops it) and never reaches the daemon under this account's lease.
    func submit(_ intent: HomeIntent) async throws -> HomeOpResult {
        if case .setTyping(let conversation, _) = intent.op {
            // Typing is not in cloud-conversations-v1 part 1: nothing is sent or
            // resent, so the key is not bound to the account.
            return HomeOpResult(rev: 0, conversation: conversation)
        }
        let key = intent.key.rawValue
        let (commands, identity, generation) = try requireEndpoint(binding: key)
        let result: HomeOpResult
        do {
            result = try await run(intent, commands: commands, identity: identity, generation: generation)
        } catch let rejection as HomeRejection {
            // Refused for good: the store never resends it. A refused send stays
            // bound, because the user may send it again with the same key.
            if Self.isFinal(rejection), !Self.isSend(intent.op) { state.withLock { _ = $0.accepted.remove(key) } }
            throw rejection
        }
        // Committed: the store never sends this key again.
        state.withLock { _ = $0.accepted.remove(key) }
        return result
    }

    private static func isSend(_ op: HomeOp) -> Bool {
        if case .sendMessage = op { true } else { false }
    }

    /// A refusal the store does not resend.
    private static func isFinal(_ rejection: HomeRejection) -> Bool {
        switch rejection {
        case .invalid, .notAuthorized: true
        default: false
        }
    }

    private func run(_ intent: HomeIntent, commands: any CloudConversationCommands, identity: CloudIdentity,
                     generation: UInt64) async throws -> HomeOpResult {
        let key = intent.key.rawValue
        func send(_ op: CloudConversationOp, in conversation: ConversationID?, key: String = key) async throws -> CloudConversationOpResult {
            let request = CloudConversationOpRequest(conversation: conversation?.rawValue, idempotencyKey: key, origin: "user", op: op)
            return try await reply(for: identity) { try await commands.op(request) }
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
            // Answered by `submit` before binding; nothing to send.
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
            if state.entries[summary.id] == nil { state.created.insert(summary.id) }
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
            // E.164 with a country code and ten national digits at least, so
            // the last four never show most of the number; anything else shows nothing.
            let digits = value.dropFirst()
            guard value.hasPrefix("+"), (11...15).contains(digits.count), digits.allSatisfy({ ("0"..."9").contains($0) }) else { return "***" }
            return "+\(digits.dropLast(10)) *** *** \(value.suffix(4))"
        }
    }

    // MARK: Events

    private func apply(_ changed: CloudConversationChanged) {
        let id = ConversationID(changed.conversation)
        publish { state in
            guard let identity = state.identity, known(id, state) else { return nil }
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
                guard mayShow(id, state), var head = state.heads[id] else { return nil }
                let reader = identity.toHome(participant)
                head.readCursors[reader] = max(head.readCursors[reader] ?? 0, seq)
                head.rev = max(head.rev, changed.rev)
                state.heads[id] = head
            case .conversation(let wire):
                guard mayShow(id, state) else { return nil }
                state.heads[id] = CloudHomeMapping.summary(wire, identity: identity)
            case .unknown:
                // An invite delivery report: no Home field changes, but the revision moves.
                guard mayShow(id, state), var head = state.heads[id] else { return nil }
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
            // UserDO owns inbox membership: a stream never lists a removed conversation again.
            guard let identity = state.identity, mayShow(id, state) else { return nil }
            let summary = CloudHomeMapping.summary(resynced.summary, identity: identity)
            state.heads[id] = summary
            return .conversationPage(ConversationPage(conversation: joined(id, state) ?? summary,
                                                      messages: resynced.messages.map { CloudHomeMapping.message($0, identity: identity) }))
        }
    }

    /// UserDO's inbox events list conversations the account has not seen
    /// yet, so they are not limited to known ones. A previous account's late
    /// inbox event leaves with the next inbox list (an entry that list does
    /// not have is removed, here and in the router's merged inbox).
    private func apply(_ changed: CloudInboxChanged) {
        var missing: [ConversationID] = []
        var unlisted: [ConversationID] = []
        var commands: (any CloudConversationCommands)?
        var generation: UInt64 = 0
        for entry in changed.entries {
            let id = ConversationID(entry.conversation)
            publish { state in
                guard state.identity != nil else { return nil }
                state.touched[id] = max(state.touched[id] ?? 0, changed.seq)
                generation = state.generation
                commands = state.commands
                state.inboxRev += 1
                state.created.remove(id)
                guard entry.isListed else {
                    state.entries[id] = nil
                    state.removed.insert(id)
                    if forget(id, &state) { unlisted.append(id) }
                    return .conversationRemoved(id, inboxRev: state.inboxRev)
                }
                state.entries[id] = entry
                state.removed.remove(id)
                if needsHead(id, state) { missing.append(id) }
                return joined(id, state).map { .conversationChanged($0, stream: .inbox, rev: state.inboxRev) }
            }
        }
        unsubscribe(unlisted, commands: commands)
        hydrate(missing, generation: generation)
    }

    private func apply(_ report: CloudSubscriptionState) {
        // Any socket live again proves the cloud reachable; a disconnect leaves intents waiting for that.
        if report.state == "disconnected" { state.withLock { $0.degraded = true } }
        if report.state == "live" { recover() }
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


    /// Subscribes once per conversation; the least recently used of 64 makes room.
    private func subscribe(_ conversation: ConversationID, commands: any CloudConversationCommands, generation: UInt64) async {
        let start = state.withLock { state -> Bool in
            guard state.generation == generation else { return false }
            if state.targets[conversation] != nil {
                state.recent.removeAll { $0 == conversation }
                state.recent.append(conversation)
                return false
            }
            if state.recent.count >= CloudConversationSubscribeRequest.maxSubscriptions {
                let oldest = state.recent.removeFirst()
                state.targets[oldest] = nil
                // Queued with the others, so opening it again at once subscribes after this ends it.
                Self.chainUnsubscribes([oldest], commands: commands, &state)
            }
            state.targets[conversation] = Target(state: "connecting")
            state.recent.append(conversation)
            return true
        }
        guard start else { return }
        await state.withLock { $0.unsubscribing }?.value
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

    /// Holds an edit while the conversation's socket reports it disconnected
    /// (`ownerUnreachable`: nothing was sent, the store resends it after
    /// `.ownerRecovered`), and refuses it once the socket is closed (the user
    /// is not a participant). A conversation without a subscription is
    /// subscribed so its echo can settle the intent (home-cloud-proxy.md section 5).
    private func requireEditable(_ conversation: ConversationID, commands: any CloudConversationCommands, generation: UInt64) throws {
        let target = state.withLock { $0.targets[conversation] }
        guard let target else {
            // task-owner: one subscribe; ends with its reply
            Task { [weak self] in await self?.subscribe(conversation, commands: commands, generation: generation) }
            return
        }
        switch target.state {
        case "disconnected":
            state.withLock { $0.degraded = true }
            throw HomeRejection.ownerUnreachable
        case "closed":
            throw HomeRejection.notAuthorized
        default:
            break
        }
    }

    // MARK: Inbox

    private func reloadInbox(generation: UInt64) async {
        guard state.withLock({ $0.generation == generation }), let inbox = try? await inbox() else { return }
        publish(generation: generation) { _ in .inbox(inbox) }
    }

    private func publishInbox() {
        publish { state in .inbox(snapshot(&state)) }
    }

    /// Queues a one-message snapshot read for each listed conversation
    /// without a current head and publishes its summary. One queue serves
    /// the whole source, so at most `hydrationWidth` reads use the daemon's
    /// request budget at once, and a conversation waits in it only once.
    private func hydrate(_ ids: [ConversationID], generation: UInt64) {
        let (commands, identity, workers) = state.withLock { state -> ((any CloudConversationCommands)?, CloudIdentity?, Int) in
            guard state.generation == generation, let commands = state.commands, let identity = state.identity else { return (nil, nil, 0) }
            let fresh = ids.filter { !state.hydrating.contains($0) }
            state.hydrating.formUnion(fresh)
            state.hydrationQueue.append(contentsOf: fresh)
            let workers = min(Self.hydrationWidth - state.hydrationWorkers, state.hydrationQueue.count)
            guard workers > 0 else { return (nil, nil, 0) }
            state.hydrationWorkers += workers
            return (commands, identity, workers)
        }
        guard let commands, let identity else { return }
        for _ in 0..<workers {
            // task-owner: one hydration worker; ends when the queue is empty or the account or connection changes
            Task { [weak self] in
                while let id = self?.nextHydration(generation: generation) {
                    await self?.hydrateOne(id, commands: commands, identity: identity, generation: generation)
                }
            }
        }
    }

    /// The next queued conversation for a worker, or nil when it ends.
    private func nextHydration(generation: UInt64) -> ConversationID? {
        state.withLock { state in
            // A configure since reset the queue and the worker count.
            guard state.generation == generation else { return nil }
            guard !state.hydrationQueue.isEmpty else {
                state.hydrationWorkers -= 1
                return nil
            }
            return state.hydrationQueue.removeFirst()
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

    /// The listed conversations, the ones this source created and not yet
    /// listed, and the open ones: a conversation the user opened (subscribed,
    /// from a deep link, a notification or the archive) stays while it is
    /// open, unless UserDO took it out of the inbox since. It leaves when
    /// its subscription ends (the least recently used of 64, a closed
    /// socket, or an account change).
    private func snapshot(_ state: inout State) -> InboxSnapshot {
        state.inboxRev += 1
        let open = Set(state.targets.keys).subtracting(state.entries.keys).subtracting(state.created).subtracting(state.removed)
        let conversations = state.entries.keys.compactMap { joined($0, state) }
            + state.created.subtracting(state.entries.keys).compactMap { joined($0, state) }
            + open.compactMap { joined($0, state) }
        return InboxSnapshot(me: me, conversations: conversations, rev: state.inboxRev)
    }

    /// Whether a conversation belongs to this generation's account: listed,
    /// created or subscribed since the last account change. A stream event
    /// of any other conversation is dropped: it can only be a previous
    /// account's, arriving after the switch (the daemon had not yet
    /// processed the unsubscribe, or reopened the socket).
    private func known(_ id: ConversationID, _ state: State) -> Bool {
        state.targets[id] != nil || state.entries[id] != nil || state.created.contains(id)
    }

    /// Whether a conversation stream event may change what the store shows:
    /// only for this account's conversations, and not while UserDO has
    /// taken the conversation out of the inbox (UserDO owns inbox
    /// membership, home-messaging.md 4.2).
    private func mayShow(_ id: ConversationID, _ state: State) -> Bool {
        known(id, state) && !state.removed.contains(id)
    }

    /// Drops what this source kept for a conversation the inbox no longer
    /// lists: its head, and its subscription, so its stream cannot list it
    /// again. Returns whether a subscription must end.
    private func forget(_ id: ConversationID, _ state: inout State) -> Bool {
        state.heads[id] = nil
        state.recent.removeAll { $0 == id }
        return state.targets.removeValue(forKey: id) != nil
    }

    /// The head with the inbox's pin and mute, or the entry alone.
    private func joined(_ id: ConversationID, _ state: State) -> CmuxHomeCore.ConversationSummary? {
        guard let identity = state.identity else { return nil }
        let entry = state.entries[id]
        guard var summary = state.heads[id] else { return entry.map { CloudHomeMapping.summary($0, identity: identity) } }
        if let entry { CloudHomeMapping.apply(entry, to: &summary) }
        return summary
    }

    /// A listed conversation whose head is missing, or behind its entry's
    /// newest message (the preview), unless its socket keeps the head
    /// current. Pin, mute and unread come from the entry itself
    /// (`CloudHomeMapping.apply`), so those changes read nothing.
    private func needsHead(_ id: ConversationID, _ state: State) -> Bool {
        guard let entry = state.entries[id], state.targets[id] == nil else { return false }
        guard let head = state.heads[id] else { return true }
        return entry.lastSeq > head.lastSeq
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

    /// The transport and account for a read, or for an intent whose key
    /// `binding` names: that key now belongs to this account, unless a
    /// previous account submitted it. Without the daemon's lease for this
    /// account nothing goes out (a reply could be another account's): the
    /// refusal waits (`ownerUnreachable`) and asks the link for a lease.
    private func requireEndpoint(binding key: String? = nil) throws -> (any CloudConversationCommands, CloudIdentity, UInt64) {
        var missing: (@Sendable () -> Void)?
        let endpoint = state.withLock { state -> Result<(any CloudConversationCommands, CloudIdentity, UInt64), HomeRejection> in
            guard let identity = state.identity else { return .failure(.notAuthorized) }
            if let key {
                if state.revoked.contains(key) { return .failure(.notAuthorized) }
                state.accepted.insert(key)
            }
            guard let commands = state.commands else {
                state.degraded = true
                return .failure(.ownerUnreachable)
            }
            guard state.leased else {
                state.degraded = true
                missing = state.leaseMissing
                return .failure(.ownerUnreachable)
            }
            return .success((commands, identity, state.generation))
        }
        missing?()
        return try endpoint.get()
    }

    /// One daemon reply for the account signed in now. A reply that arrives
    /// after sign-out or an account switch is refused (`notAuthorized`), so
    /// no page of the previous account reaches the store. A failure that
    /// leaves intents unconfirmed marks the source degraded; a good reply
    /// recovers it.
    private func reply<T>(for identity: CloudIdentity, _ body: () async throws -> T) async throws -> T {
        let value: T
        do {
            value = try await Self.mapped(body)
        } catch let rejection as HomeRejection {
            // Only the account that sent it waits for a recovery.
            if rejection == .indeterminate || rejection == .ownerUnreachable {
                state.withLock { if $0.identity?.cloudID == identity.cloudID { $0.degraded = true } }
            }
            throw rejection
        }
        guard state.withLock({ $0.identity?.cloudID }) == identity.cloudID else { throw HomeRejection.notAuthorized }
        recover()
        return value
    }

    /// Ends subscriptions of conversations the inbox no longer lists.
    private func unsubscribe(_ ids: [ConversationID], commands: (any CloudConversationCommands)?) {
        guard let commands, !ids.isEmpty else { return }
        state.withLock { Self.chainUnsubscribes(ids, commands: commands, &$0) }
    }

    /// Queues unsubscribes after the ones queued before (call with the lock held).
    private static func chainUnsubscribes(_ ids: [ConversationID], commands: any CloudConversationCommands, _ state: inout State) {
        let prior = state.unsubscribing
        // task-owner: one unsubscribe per conversation, after the earlier ones; ends with the replies
        state.unsubscribing = Task {
            await prior?.value
            for id in ids { _ = try? await commands.unsubscribe(id.rawValue) }
        }
    }

    /// The cloud is reachable again after a failure: the store resends.
    private func recover() {
        publish { state in
            guard state.degraded, state.identity != nil, state.leased, state.commands != nil else { return nil }
            state.degraded = false
            return .ownerRecovered
        }
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

    /// An inbox list's revision as the inbox stream seq (UserDO sends
    /// `String(currentSeq)`); nil when it is not one.
    static func revision(_ value: JSONValue?) -> UInt64? {
        switch value {
        case .string(let text): UInt64(text)
        case .number(let number) where number >= 0 && number < 1.8e19 && number.rounded() == number: UInt64(number)
        default: nil
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
