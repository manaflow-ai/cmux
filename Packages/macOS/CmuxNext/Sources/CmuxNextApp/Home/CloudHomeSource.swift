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
nonisolated final class CloudHomeSource: HomeSource {
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

    fileprivate struct State {
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

    fileprivate let state = Mutex(State())
    private static let eventBuffer = 1024
    static let inboxLimit = CloudInboxListRequest.maxLimit
    static let hydrationWidth = 4
    /// How long an edit made outside a transcript keeps its conversation
    /// subscribed for its echo after its op answered (or was refused and
    /// may not be resent) before the subscription ends anyway.
    static let editEchoDeadline: Duration = .seconds(30)
    /// The local user's participant in this store (`CloudIdentity.localID`).
    let me: Participant
    /// Paces the edit echo deadline (tests pass a manual clock).
    fileprivate let clock: any Clock<Duration>

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

    /// Called (off any lock) when an op or read is refused because the
    /// daemon holds no lease for this account: nothing reaches the daemon
    /// then, so the daemon never asks for one itself.
    func onLeaseMissing(_ action: @escaping @Sendable () -> Void) {
        state.withLock { $0.leaseMissing = action }
    }

    /// Called (off any lock) when the first reply, live socket or owner
    /// event after a renewed lease shows the Worker takes its token.
    func onLeaseProven(_ action: @escaping @Sendable () -> Void) {
        state.withLock { $0.leaseProven = action }
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
    fileprivate func isForThisAccount(_ event: CloudConversationsEvent) -> Bool {
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

    /// The daemon took a new lease for `subject` (a Stack user id). Only a
    /// lease for the account this source acts as counts: refused ops can go
    /// through again, and an account that waited for its first lease lists
    /// its inbox. A lease for another account changes nothing here.
    func leaseRenewed(subject: String) {
        let renewed = state.withLock { state -> (first: Bool, generation: UInt64)? in
            guard let identity = state.identity, identity.cloudID == CloudIdentity.cloudID(stackUserID: subject) else { return nil }
            defer {
                state.leased = true
                // A lease is not proof: the Worker may refuse its token too.
                state.proven = false
                state.leaseEpoch += 1
            }
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
    fileprivate func leaseArrived(generation: UInt64) {
        recover()
        // task-owner: one inbox list; ends with its reply
        Task { [weak self] in await self?.reloadInbox(generation: generation) }
    }

    // MARK: HomeSource
}
