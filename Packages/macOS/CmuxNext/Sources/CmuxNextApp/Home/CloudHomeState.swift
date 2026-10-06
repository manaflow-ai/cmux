import CmuxHomeCore
import CmuxNextDaemon
import CmuxNextWakeups
import Foundation

/// What `CloudHomeSource` keeps, guarded by its `state` lock: the
/// connection and account, the inbox projection, the subscriptions and
/// the intents waiting to be confirmed. Every method here runs with that
/// lock held.
nonisolated struct CloudHomeState {
    /// A subscribed conversation and the last state its socket reported.
    struct Target: Hashable, Sendable {
        var state: String
        /// An event set `state`; the subscribe reply no longer may.
        var fromEvent = false
    }

    /// The subscription an edit made outside a transcript keeps for its
    /// echo (`requireEditable` subscribed the conversation for it).
    struct EditHold {
        /// Edits of the conversation whose op has not answered yet.
        var inFlight = 0
        /// The newest revision an answered op committed at: an event at
        /// it or later is the echo, and ends the hold.
        var awaited: UInt64?
        /// The newest revision a conversation event reported since the hold began.
        var seen: UInt64 = 0
        /// Ends the hold when no echo comes (a lost echo, or a refusal the
        /// store gives up on without telling the source).
        let deadline: DemandTimer
    }

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
    /// Tells the link a reply or a live socket came through the lease.
    var leaseProven: (@Sendable () -> Void)?
    /// A reply, a live socket or an owner event came through the
    /// current lease since it was renewed: the Worker takes its token.
    var proven = true
    /// Bumps with every renewed lease. A reply proves only the lease it
    /// was sent under: one sent before the renewal proves nothing new.
    var leaseEpoch: UInt64 = 0
    /// Bumps on every configure; work started under an older one is dropped.
    var generation: UInt64 = 0
    var entries: [ConversationID: CloudInboxEntry] = [:]
    /// People the user can reach that no head names yet (team members and
    /// connections from the Home directory), by Home id: their names for a
    /// new group's participants.
    var directory: [ParticipantID: Participant] = [:]
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
    /// Conversations whose socket the owner refused (`closed`: the user
    /// is not a participant). An edit there is refused and subscribes
    /// nothing, until the inbox lists the conversation again or the user
    /// opens it. Emptied when the account changes.
    var closed: Set<ConversationID> = []
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
    /// Keys of intents a previous account submitted, with that account's
    /// cloud id. Refused for good under any other account, so none goes
    /// out under another identity (the owner scopes keys per actor). An
    /// account's own keys leave when it signs in again.
    var revoked: [String: String] = [:]
    /// The subscribes and unsubscribes sent so far, one after another in
    /// the order they were queued, so a late unsubscribe never ends a
    /// subscription made after it and an unsubscribe never overtakes the
    /// subscribe it ends. A new connection starts a new queue.
    var wire: Task<Void, Never>?
    /// Conversations a transcript shows now (read with `snapshot(of:)`
    /// and not closed since). An edit from outside a transcript
    /// subscribes a conversation for itself and ends that with its echo.
    var viewed: Set<ConversationID> = []
    /// Edits outside a transcript waiting for their echo, per conversation.
    var editHolds: [ConversationID: EditHold] = [:]
    /// This source's inbox stream revision: one per inbox event it publishes.
    var inboxRev: Revision = 0
    /// A read or op failed in a way that leaves intents unconfirmed; the
    /// next sign that the cloud is reachable publishes `.ownerRecovered`.
    var degraded = false
    #if DEBUG
    /// Test seam: awaited by `snapshot(of:)` after it marks the
    /// conversation viewed and before it subscribes.
    var snapshotWillSubscribe: (@Sendable () async -> Void)?
    #endif
}

nonisolated extension CloudHomeState {
    // MARK: State helpers (call with the lock held)

    /// The listed conversations, the ones this source created and not yet
    /// listed, and the open ones: a conversation the user opened (subscribed,
    /// from a deep link, a notification or the archive) stays while it is
    /// on screen, unless UserDO took it out of the inbox since. It leaves
    /// when its subscription ends (its transcript closed, the least recently
    /// used of 64, a closed socket, or an account change).
    mutating func snapshot(me: Participant) -> InboxSnapshot {
        inboxRev += 1
        let open = Set(targets.keys).subtracting(entries.keys).subtracting(created).subtracting(removed)
        let conversations = entries.keys.compactMap { joined($0) }
            + created.subtracting(entries.keys).compactMap { joined($0) }
            + open.compactMap { joined($0) }
        return InboxSnapshot(me: me, conversations: conversations, rev: inboxRev)
    }

    /// Whether a conversation belongs to this generation's account: listed,
    /// created or subscribed since the last account change. A stream event
    /// of any other conversation is dropped: it can only be a previous
    /// account's, arriving after the switch (the daemon had not yet
    /// processed the unsubscribe, or reopened the socket).
    func known(_ id: ConversationID) -> Bool {
        targets[id] != nil || entries[id] != nil || created.contains(id)
    }

    /// Whether a conversation stream event may change what the store shows:
    /// only for this account's conversations, and not while UserDO has
    /// taken the conversation out of the inbox (UserDO owns inbox
    /// membership, home-messaging.md 4.2).
    func mayShow(_ id: ConversationID) -> Bool {
        known(id) && !removed.contains(id)
    }

    /// Drops what this source kept for a conversation the inbox no longer
    /// lists: its head, and its subscription, so its stream cannot list it
    /// again. Returns whether a subscription must end.
    mutating func forget(_ id: ConversationID) -> Bool {
        heads[id] = nil
        recent.removeAll { $0 == id }
        return targets.removeValue(forKey: id) != nil
    }

    /// The head with the inbox's pin and mute, or the entry alone.
    func joined(_ id: ConversationID) -> CmuxHomeCore.ConversationSummary? {
        guard let identity else { return nil }
        let entry = entries[id]
        guard var summary = heads[id] else { return entry.map { CloudHomeMapping.summary($0, identity: identity) } }
        if let entry { CloudHomeMapping.apply(entry, to: &summary) }
        return summary
    }

    /// A listed conversation whose head is missing, or behind its entry's
    /// newest message (the preview), unless its socket keeps the head
    /// current. Pin, mute and unread come from the entry itself
    /// (`CloudHomeMapping.apply`), so those changes read nothing.
    func needsHead(_ id: ConversationID) -> Bool {
        guard let entry = entries[id], targets[id] == nil else { return false }
        guard let head = heads[id] else { return true }
        return entry.lastSeq > head.lastSeq
    }

    /// The listed conversations that need a head, in a stable order.
    func missingHeads() -> [ConversationID] {
        entries.keys.filter { needsHead($0) }.sorted { $0.rawValue < $1.rawValue }
    }

    /// A participant for `conversation.create`, as a known head names it.
    func participantRecord(_ id: ParticipantID, identity: CloudIdentity) -> ConversationParticipant {
        let known = heads.values.lazy.flatMap(\.participants).first { $0.id == id } ?? directory[id]
        let wireID = identity.toCloud(id)
        let isAgent = known.map { $0.kind == .agent } ?? wireID.hasPrefix("agent_")
        return ConversationParticipant(id: wireID, kind: isAgent ? .agent : .human, displayName: known?.displayName ?? wireID,
                                       agentClass: isAgent ? (known?.agentClass == .chief ? "mux" : "agent") : nil)
    }

    /// Queues unsubscribes after the subscribes and unsubscribes queued
    /// before (call with the lock held).
    mutating func chainUnsubscribes(_ ids: [ConversationID], commands: any CloudConversationCommands) {
        let prior = wire
        // task-owner: one unsubscribe per conversation, after the earlier ones; ends with the replies
        wire = Task {
            await prior?.value
            for id in ids { _ = try? await commands.unsubscribe(id.rawValue) }
        }
    }

    /// Queues a subscribe after the subscribes and unsubscribes queued
    /// before; the task answers with its reply (call with the lock held).
    mutating func chainSubscribe(_ id: ConversationID,
                                 commands: any CloudConversationCommands) -> Task<Result<CloudSubscription, any Error>, Never> {
        let prior = wire
        // task-owner: one subscribe, after the earlier ones; ends with its reply
        let sent = Task { () -> Result<CloudSubscription, any Error> in
            await prior?.value
            do { return .success(try await commands.subscribe(id.rawValue)) } catch { return .failure(error) }
        }
        // task-owner: the queue's link to that subscribe; ends with it
        wire = Task { _ = await sent.value }
        return sent
    }

    /// The held edit is done: no transcript shows its conversation, so the
    /// subscription `requireEditable` made for it ends (call with the lock
    /// held).
    mutating func endEditSubscription(_ conversation: ConversationID) {
        editHolds.removeValue(forKey: conversation)?.deadline.cancel()
        guard !viewed.contains(conversation), let commands,
              targets.removeValue(forKey: conversation) != nil else { return }
        recent.removeAll { $0 == conversation }
        chainUnsubscribes([conversation], commands: commands)
    }
}
