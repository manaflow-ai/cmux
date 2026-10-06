import CmuxHomeCore
import CmuxNextDaemon
import CmuxNextWakeups
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
///
/// The source is split by concern across `CloudHomeSource+*.swift` and its
/// state, with the helpers that read it under the lock, lives in
/// `CloudHomeState`. Members those files share are internal instead of
/// private only so the sibling files reach them; nothing else calls them.
nonisolated final class CloudHomeSource: HomeSource {
    /// Everything this source keeps, under one lock. Internal (not private)
    /// only so the `CloudHomeSource+*.swift` extensions reach it.
    let state = Mutex(CloudHomeState())
    static let eventBuffer = 1024
    static let inboxLimit = CloudInboxListRequest.maxLimit
    static let hydrationWidth = 4
    /// How long an edit made outside a transcript keeps its conversation
    /// subscribed for its echo after its op answered (or was refused and
    /// may not be resent) before the subscription ends anyway.
    static let editEchoDeadline: Duration = .seconds(30)
    /// The local user's participant in this store (`CloudIdentity.localID`).
    let me: Participant
    /// Paces the edit echo deadline (tests pass a manual clock).
    let clock: any Clock<Duration>

    init(me: Participant, clock: any Clock<Duration> = ContinuousClock()) {
        self.me = me
        self.clock = clock
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
                if let ended = state.identity?.cloudID {
                    for key in state.accepted { state.revoked[key] = ended }
                }
                if let next = identity?.cloudID { state.revoked = state.revoked.filter { $0.value != next } }
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
            // Another connection's queue orders nothing on this one.
            if link != state.link { state.wire = nil }
            if let old = state.commands, !ended.isEmpty {
                // The previous account's subscriptions end before the next one subscribes.
                state.chainUnsubscribes(ended, commands: old)
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
            // Subscriptions of the old connection or account are not this one's to end.
            for hold in state.editHolds.values { hold.deadline.cancel() }
            state.editHolds = [:]
            if cleared {
                state.entries = [:]
                state.touched = [:]
                state.created = []
                state.removed = []
                state.closed = []
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
        // The kept conversations subscribe before the inbox lists: a list
        // without them would take them out of the merged inbox (the router
        // removes what a cloud inbox leaves out) while they are on screen.
        // task-owner: one inbox subscribe, the kept conversations' subscribes, then one list; ends with their replies
        Task { [weak self] in
            _ = try? await commands.subscribeInbox()
            for id in kept { await self?.subscribe(id, commands: commands, generation: generation) }
            await self?.reloadInbox(generation: generation)
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
        if case .changed(let changed) = event { echoed(ConversationID(changed.conversation), rev: changed.rev) }
        if case .resynced(let resynced) = event { echoed(ConversationID(resynced.conversation), rev: resynced.rev) }
        // An owner event proves the cloud reachable again.
        if case .changed = event { reached() }
        if case .resynced = event { reached() }
        if case .inboxChanged = event { reached() }
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

    /// An event that names its account (the lease's `sub`) belongs to
    /// this source only when that is the account it acts as: another one's
    /// is a late event from before a switch, and is dropped.
    private func isForThisAccount(_ event: CloudConversationsEvent) -> Bool {
        Self.isForAccount(event, cloudID: state.withLock { $0.identity?.cloudID })
    }

    /// Whether `event` belongs to the account whose cloud id is `cloudID`
    /// (nil: none). The daemon tags every event with the `sub` of the
    /// socket's lease and leaves it out only for a lease without a readable
    /// `sub` (which this app never sets) or a `disconnected` state without
    /// a lease (home-cloud-proxy.md section 5). So a data event (a change,
    /// a resync, an inbox change) without one is refused; a socket state or
    /// an inbox reset without one carries no data and is kept.
    static func isForAccount(_ event: CloudConversationsEvent, cloudID: String?) -> Bool {
        let account: String?
        switch event {
        case .changed(let changed): account = changed.account
        case .resynced(let resynced): account = resynced.account
        case .inboxChanged(let changed): account = changed.account
        case .inboxReset(_, let named): return named.map { cloudID == CloudIdentity.cloudID(stackUserID: $0) } ?? true
        case .subscriptionState(let report): return report.account.map { cloudID == CloudIdentity.cloudID(stackUserID: $0) } ?? true
        case .sessionNeeded: return true
        }
        guard let account else { return false }
        return cloudID == CloudIdentity.cloudID(stackUserID: account)
    }

    /// The account this source acts as (its cloud id), leased or not.
    var accountID: String? { state.withLock { $0.identity?.cloudID } }
}
