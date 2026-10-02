import Foundation
import Testing
@testable import CmuxNextDaemon

/// Seeded property tests for the confirmed mirror plus the intent log
/// (OWNERSHIP-PRINCIPLES.md, "Verification": "seeded property tests for ...
/// the mirror + intent log against a reference model").
///
/// A reference owner (`RefState`) holds three panes of tabs with names and
/// pins, four workspaces with names, order and groups, and the collapse
/// state of two workspace groups and one tab group. Each step does one
/// random thing: the client intends a change of any kind (moveTab,
/// renameTab, setTabPinned, renameWorkspace, moveWorkspace,
/// setWorkspaceGroup, placeWorkspace, either collapse; sent in order on the
/// control connection), the owner serves the next request (applies or
/// rejects it; a change that changes nothing emits nothing, like
/// cmux-tui), another client changes any of the same state or closes or
/// opens tabs and panes, the client receives a batch of events (sometimes a
/// repeated delta, sometimes a `tree-changed` that forces a resync; a
/// collapse is reported only as `tree-changed`), a reply, or a resync whose
/// snapshot is newer than events still in flight (they arrive later and
/// are skipped by the snapshot barrier), or a new connection whose event
/// sequences restart below the old ones (requests in flight fail, some
/// after the owner applied them). After every step:
///
/// - conservation: the visible tabs are exactly the confirmed tabs, none
///   duplicated or lost;
/// - an unsettled move stays visible, and the whole visible state is
///   exactly the confirmed one plus the pending intents applied in order;
/// - no intent settles twice, nor before its outcome reached the store;
/// - convergence: with an empty log and no resync pending, the visible
///   state equals the confirmed one, which equals the owner's at the
///   store's sequence.
///
/// At the end everything drains: every intent settled exactly once, the
/// visible state equals the owner's, and the debug single-writer check
/// found nothing.
@MainActor @Suite struct IntentLogPropertyTests {
    static let seedsPerCase = 250
    static let steps = 80

    @Test(arguments: 0..<8)
    func mirrorAndIntentLogKeepTheirInvariants(chunk: Int) async throws {
        let template = try Fixture.response(DaemonTree.self, "list-workspaces.json")
        for seed in (chunk * Self.seedsPerCase)..<((chunk + 1) * Self.seedsPerCase) {
            var world = IntentWorld(seed: UInt64(seed), template: template)
            try world.run(steps: Self.steps)
            // Each seed runs on the main actor; yield between seeds so the
            // package's other main-actor tests (socket round trips with
            // deadlines) are not starved for the whole chunk.
            await Task.yield()
        }
    }
}

@MainActor struct IntentWorld {
    struct Request { let transaction: ClientTransactionID; let intent: Intent }
    struct Reply { let transaction: ClientTransactionID; let ok: Bool; let barrier: UInt64 }

    var random: IntentRandom
    let seed: UInt64
    let template: DaemonTree
    let store = DaemonStore()

    var owner: RefState
    /// The owner's workspace revision (every workspace delta adds one).
    var revision: UInt64
    /// What a store that applied every delta up to each event sequence of
    /// this connection shows (collapse fields aside: see `confirmed`).
    var history: [UInt64: RefState]
    var sequence: UInt64 = 0
    /// Connections so far; a new one numbers its events from the start
    /// again (a new `DaemonConnection` restarts its serial).
    var connection = 0
    /// The owner state the store's confirmed records reflect. Workspace
    /// group collapse arrives only in snapshots; the tab group's collapse
    /// also with each workspace delta of the workspace holding it.
    var confirmed: RefState
    var nextSurface: UInt64 = 100
    var nextTransaction = 0

    var outbox: [Request] = []
    var events: [DaemonEventEnvelope] = []
    var replies: [Reply] = []
    var resyncPending = false
    /// The owner sequence the store's confirmed records reflect (last
    /// applied event, or the last snapshot's barrier).
    var mirrorSequence: UInt64 = 0

    /// Pending intents in order (the reference log).
    var pending: [(transaction: ClientTransactionID, intent: Intent)] = []
    var sent: Set<ClientTransactionID> = []
    /// Served requests: accepted (with the reply's barrier and connection) or rejected.
    var served: [ClientTransactionID: (ok: Bool, barrier: UInt64, connection: Int)] = [:]
    /// Replied on a connection that ended: known once a later snapshot applied.
    var awaitingSnapshot: Set<ClientTransactionID> = []
    var knownBySnapshot: Set<ClientTransactionID> = []
    var settledSeen: Set<ClientTransactionID> = []
    var repliesDelivered: Set<ClientTransactionID> = []
    var echoesDelivered: Set<ClientTransactionID> = []
    var trace: [String] = []

    init(seed: UInt64, template: DaemonTree) {
        self.seed = seed
        random = IntentRandom(state: seed)
        self.template = template
        var tabs: [PaneID: [SurfaceID]] = [:]
        var meta: [SurfaceID: RefTabMeta] = [:]
        var surface: UInt64 = 1
        for pane in RefLayout.panes {
            let count = Int.random(in: 1...3, using: &random)
            tabs[pane] = (0..<count).map { _ in
                defer { surface += 1 }
                meta[SurfaceID(rawValue: surface)] = RefTabMeta()
                return SurfaceID(rawValue: surface)
            }
        }
        var workspaces = [RefWorkspace(key: RefState.main, handle: 1, name: "beta", group: nil)]
        for (offset, key) in ["wa", "wb", "wc"].enumerated() {
            let group = [nil, "g1", "g2"][Int.random(in: 0..<3, using: &random)].map(WorkspaceGroupID.init(rawValue:))
            workspaces.append(RefWorkspace(key: WorkspaceKey(rawValue: key), handle: WorkspaceHandle(rawValue: UInt64(40 + offset)),
                                           name: key, group: group))
        }
        owner = RefState(layout: RefLayout(tabs: tabs), meta: meta, workspaces: workspaces,
                         groupCollapsed: ["g1": false, "g2": false], tabGroupCollapsed: false)
        revision = template.workspaceRevision
        history = [0: owner]
        confirmed = owner
    }

    // MARK: Run

    mutating func run(steps: Int) throws {
        store.apply(snapshot: tree(owner))
        let log = IntentSettleLog()
        store.onIntentSettled = { transaction, _ in log.record(transaction) }
        for _ in 0..<steps {
            step()
            try check(log)
        }
        try drain(log)
    }

    mutating func step() {
        switch Int.random(in: 0..<100, using: &random) {
        case 0..<22: intend()
        case 22..<40: serve()
        case 40..<50: external()
        case 50..<72: deliverEvents()
        case 72..<90: deliverReply()
        case 90..<97: resync()
        default: reconnect()
        }
    }

    /// Delivers everything until the log is empty and nothing is in flight.
    mutating func drain(_ log: IntentSettleLog) throws {
        var rounds = 0
        while !outbox.isEmpty || !events.isEmpty || !replies.isEmpty || resyncPending {
            rounds += 1
            try require(rounds < 10_000, "drain did not finish")
            if resyncPending { resync() } else if !outbox.isEmpty { serve() } else if !events.isEmpty { deliverEvents(all: true) } else { deliverReply() }
            try check(log)
        }
        try require(!store.hasPendingIntents, "intents left after drain: \(store.pendingIntents)")
        for transaction in sent { try require(log.count(transaction) == 1, "\(transaction) settled \(log.count(transaction)) times") }
        try require(visible() == owner, "drained visible \(visible()) != owner \(owner)")
        try require(store.mirrorViolations.isEmpty, "mirror violations: \(store.mirrorViolations)")
    }

    // MARK: Client

    mutating func intend() {
        guard let intent = randomIntent(in: visible()) else { return }
        nextTransaction += 1
        let transaction = ClientTransactionID(rawValue: "t\(nextTransaction)")
        trace.append("intend \(transaction) \(intent)")
        store.intend(intent, transaction: transaction)
        pending.append((transaction, intent))
        sent.insert(transaction)
        outbox.append(Request(transaction: transaction, intent: intent))
    }

    /// A random change of any kind to what `state` shows (the user acts
    /// on the visible state).
    mutating func randomIntent(in state: RefState) -> Intent? {
        let surface = state.layout.allTabs.randomElement(using: &random)
        let key = state.workspaces.randomElement(using: &random)!.key
        let group = [nil, "g1", "g2"].randomElement(using: &random)!.map(WorkspaceGroupID.init(rawValue:))
        switch Int.random(in: 0..<10, using: &random) {
        case 0..<3:
            return surface.map { .moveTab(surface: $0, toPane: RefLayout.panes.randomElement(using: &random)!, index: Int.random(in: 0...4, using: &random)) }
        case 3: return surface.map { .renameTab(surface: $0, name: ["a", "b", nil].randomElement(using: &random)!) }
        case 4: return surface.map { .setTabPinned(surface: $0, pinned: Bool.random(using: &random)) }
        case 5: return .renameWorkspace(key: key, name: ["x", "y", "z"].randomElement(using: &random)!)
        case 6: return .moveWorkspace(key: key, index: Int.random(in: 0...4, using: &random))
        case 7: return Bool.random(using: &random) ? .setWorkspaceGroup(key: key, group: group)
            : .placeWorkspace(key: key, group: group, index: Int.random(in: 0...3, using: &random))
        case 8: return .setWorkspaceGroupCollapsed(RefState.groups.randomElement(using: &random)!, collapsed: Bool.random(using: &random))
        default: return .setTabGroupCollapsed(RefState.tabGroup, collapsed: Bool.random(using: &random))
        }
    }

    mutating func deliverEvents(all: Bool = false) {
        guard !events.isEmpty, !resyncPending else { return }
        let count = all ? events.count : Int.random(in: 1...events.count, using: &random)
        var batch = Array(events.prefix(count))
        events.removeFirst(count)
        // A repeated delta right after itself (the daemon resends a tab's
        // state): applying it twice must change nothing.
        if Bool.random(using: &random), let index = batch.indices.randomElement(using: &random),
           case .tabChanged = batch[index].event {
            batch.insert(batch[index], at: index + 1)
        }
        trace.append("events \(batch.map(\.sequence))")
        for envelope in batch { if let transaction = envelope.event.clientTransactionID { echoesDelivered.insert(transaction) } }
        let barrier = store.snapshotBarrier
        var tabGroupCollapsed = confirmed.tabGroupCollapsed
        for envelope in batch where envelope.sequence > barrier {
            if let collapsed = Self.tabGroupCollapse(in: envelope.event) { tabGroupCollapsed = collapsed }
        }
        if store.apply(batch: batch) == .resync { resyncPending = true }
        if let last = batch.map(\.sequence).filter({ $0 > barrier }).max() {
            mirrorSequence = max(mirrorSequence, last)
            let groups = confirmed.groupCollapsed
            confirmed = history[mirrorSequence]!
            confirmed.groupCollapsed = groups
            confirmed.tabGroupCollapsed = tabGroupCollapsed
        }
    }

    mutating func deliverReply() {
        guard !replies.isEmpty else { return }
        let reply = replies.removeFirst()
        trace.append("reply \(reply.transaction) ok=\(reply.ok) barrier=\(reply.barrier)")
        repliesDelivered.insert(reply.transaction)
        if reply.ok {
            store.noteSettled(reply.transaction, at: reply.barrier)
        } else {
            store.rejectIntent(reply.transaction)
        }
    }

    /// The driver's resync: a snapshot of the owner now (possibly newer
    /// than events and replies still in flight), then its barrier.
    mutating func resync() {
        trace.append("resync at \(sequence)")
        store.apply(snapshot: tree(owner))
        store.snapshotBarrier = max(store.snapshotBarrier, sequence)
        store.advanceAppliedSequence(to: sequence)
        mirrorSequence = max(mirrorSequence, sequence)
        confirmed = owner
        knownBySnapshot.formUnion(awaitingSnapshot)
        awaitingSnapshot.removeAll()
        resyncPending = false
    }

    /// The connection ends for good and a new one starts (a Cloud machine's
    /// link): events in flight are lost, requests in flight fail (some of
    /// them were applied), and the new connection's event sequences start
    /// below the old ones. Its `connected` event resyncs.
    mutating func reconnect() {
        trace.append("reconnect")
        events.removeAll()
        for reply in replies { fail(reply.transaction) }
        for request in outbox { fail(request.transaction) }
        replies.removeAll()
        outbox.removeAll()
        awaitingSnapshot.formUnion(Set(served.filter { $0.value.ok && $0.value.connection == connection }.keys).intersection(repliesDelivered))
        connection += 1
        sequence = 0
        history = [0: owner]
        mirrorSequence = 0
        store.beginConnection()
        resyncPending = true
    }

    private mutating func fail(_ transaction: ClientTransactionID) {
        served[transaction] = (false, 0, connection)
        repliesDelivered.insert(transaction)
        store.rejectIntent(transaction)
    }

    func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        guard condition else { throw failure(message()) }
    }

    func failure(_ message: String) -> IntentPropertyFailure {
        let recent = trace.suffix(16).joined(separator: "\n")
        Issue.record(Comment(rawValue: "seed \(seed): \(message)\n\(recent)"))
        return IntentPropertyFailure()
    }
}
