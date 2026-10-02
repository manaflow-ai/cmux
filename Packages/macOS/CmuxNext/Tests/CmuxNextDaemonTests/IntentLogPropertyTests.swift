import Foundation
import Testing
@testable import CmuxNextDaemon

/// Seeded property tests for the confirmed mirror plus the intent log
/// (OWNERSHIP-PRINCIPLES.md, "Verification": "seeded property tests for ...
/// the mirror + intent log against a reference model").
///
/// A reference owner holds the layout of three panes. Each step does one
/// random thing: the client intends a move (sent in order on the control
/// connection), the owner serves the next request (applies or rejects it;
/// a move to the tab's own place emits nothing, like cmux-tui), another
/// client moves, closes or opens a tab or closes or opens a pane (with its
/// tabs), the client receives a batch of
/// events (sometimes with a repeated delta, sometimes a `tree-changed`
/// that forces a resync), a reply, or a resync whose snapshot is newer
/// than events still in flight (they arrive later and are skipped by the
/// snapshot barrier), or a new connection whose event sequences restart
/// below the old ones (requests in flight fail, some after the owner
/// applied them). After every step:
///
/// - conservation: the visible tabs are exactly the confirmed tabs, none
///   duplicated or lost;
/// - an unsettled intent stays visible (its tab shows in its target pane),
///   and the visible layout is exactly the confirmed one plus the pending
///   intents applied in order;
/// - no intent settles twice;
/// - convergence: with an empty log and no resync pending, the visible
///   layout equals the owner's layout at the store's sequence.
///
/// At the end everything drains: every intent settled exactly once, the
/// visible layout equals the owner's, and the debug single-writer check
/// found nothing.
@MainActor @Suite struct IntentLogPropertyTests {
    static let seedsPerCase = 250
    static let steps = 80

    @Test(arguments: 0..<8)
    func mirrorAndIntentLogKeepTheirInvariants(chunk: Int) throws {
        let template = try Fixture.response(DaemonTree.self, "list-workspaces.json")
        for seed in (chunk * Self.seedsPerCase)..<((chunk + 1) * Self.seedsPerCase) {
            var world = World(seed: UInt64(seed), template: template)
            try world.run(steps: Self.steps)
        }
    }
}

/// splitmix64: small, seedable, the same sequence on every machine.
private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The owner's layout: panes in order, each with its tabs in order. A pane
/// of `panes` without an entry is closed.
private struct Layout: Equatable, CustomStringConvertible {
    static let panes: [PaneID] = [4, 7, 21]
    var tabs: [PaneID: [SurfaceID]]

    var description: String { Self.panes.map { "\($0):\(tabs[$0].map { "\($0)" } ?? "closed")" }.joined(separator: " ") }
    var openPanes: [PaneID] { Self.panes.filter { tabs[$0] != nil } }
    var allTabs: [SurfaceID] { Self.panes.flatMap { tabs[$0] ?? [] } }

    func pane(of surface: SurfaceID) -> PaneID? { Self.panes.first { tabs[$0]?.contains(surface) == true } }

    /// cmux-tui `move-tab` with a final index; returns false when nothing
    /// moved (no event): the tab or the pane is missing, or the tab is at
    /// its place.
    mutating func move(_ surface: SurfaceID, to pane: PaneID, index: Int) -> Bool {
        guard tabs[pane] != nil, let source = self.pane(of: surface), let from = tabs[source]?.firstIndex(of: surface) else { return false }
        if source == pane {
            let final = min(max(index, 0), tabs[pane]!.count - 1)
            guard final != from else { return false }
            tabs[pane]!.remove(at: from)
            tabs[pane]!.insert(surface, at: final)
        } else {
            tabs[source]!.remove(at: from)
            tabs[pane]!.insert(surface, at: min(max(index, 0), tabs[pane]!.count))
        }
        return true
    }
}

@MainActor private struct World {
    struct Request { let transaction: ClientTransactionID; let surface: SurfaceID; let pane: PaneID; let index: Int }
    struct Reply { let transaction: ClientTransactionID; let ok: Bool; let barrier: UInt64 }

    var random: SeededRandom
    let seed: UInt64
    let template: DaemonTree
    let store = DaemonStore()

    var owner: Layout
    /// The owner's layout after each event sequence of this connection.
    var history: [UInt64: Layout]
    var sequence: UInt64 = 0
    /// Connections so far; a new one numbers its events from the start
    /// again (a new `DaemonConnection` restarts its serial).
    var connection = 0
    /// The owner layout the store's confirmed records reflect.
    var confirmed: Layout
    var nextSurface: UInt64 = 100
    var nextTransaction = 0

    var outbox: [Request] = []
    var events: [DaemonEventEnvelope] = []
    var replies: [Reply] = []
    var resyncPending = false
    /// The owner sequence the store's confirmed records reflect (last
    /// applied event, or the last snapshot's barrier).
    var mirrorSequence: UInt64 = 0

    /// Pending intents by transaction (the reference log).
    var pending: [(transaction: ClientTransactionID, surface: SurfaceID, pane: PaneID, index: Int)] = []
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
        random = SeededRandom(state: seed)
        self.template = template
        var tabs: [PaneID: [SurfaceID]] = [:]
        var surface: UInt64 = 1
        for pane in Layout.panes {
            let count = Int.random(in: 1...3, using: &random)
            tabs[pane] = (0..<count).map { _ in
                defer { surface += 1 }
                return SurfaceID(rawValue: surface)
            }
        }
        owner = Layout(tabs: tabs)
        history = [0: owner]
        confirmed = owner
    }

    // MARK: Run

    mutating func run(steps: Int) throws {
        store.apply(snapshot: tree(owner))
        let log = SettleLog()
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
    mutating func drain(_ log: SettleLog) throws {
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
        let tabs = visible().allTabs
        guard let surface = tabs.randomElement(using: &random) else { return }
        let pane = Layout.panes.randomElement(using: &random)!
        let index = Int.random(in: 0...4, using: &random)
        nextTransaction += 1
        let transaction = ClientTransactionID(rawValue: "t\(nextTransaction)")
        trace.append("intend \(transaction) \(surface)->\(pane)@\(index)")
        store.intend(.moveTab(surface: surface, toPane: pane, index: index), transaction: transaction)
        pending.append((transaction, surface, pane, index))
        sent.insert(transaction)
        outbox.append(Request(transaction: transaction, surface: surface, pane: pane, index: index))
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
        if store.apply(batch: batch) == .resync { resyncPending = true }
        if let last = batch.map(\.sequence).filter({ $0 > barrier }).max() {
            mirrorSequence = max(mirrorSequence, last)
            confirmed = history[mirrorSequence]!
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

    // MARK: Owner

    mutating func serve() {
        guard !outbox.isEmpty else { return }
        let request = outbox.removeFirst()
        let roll = Int.random(in: 0..<100, using: &random)
        let exists = owner.pane(of: request.surface) != nil && owner.tabs[request.pane] != nil
        guard roll >= 8, exists else {
            trace.append("reject \(request.transaction)")
            served[request.transaction] = (false, sequence, connection)
            replies.append(Reply(transaction: request.transaction, ok: false, barrier: sequence))
            return
        }
        if owner.move(request.surface, to: request.pane, index: request.index) {
            // cmux-tui's move-tab emits tree-changed (sometimes) and the
            // moved tab's tab-changed echoing the transaction.
            if Int.random(in: 0..<4, using: &random) == 0 { emit(.treeChanged(transaction: nil)) }
            let echo = Int.random(in: 0..<5, using: &random) != 0
            emit(tabChanged(request.surface, transaction: echo ? request.transaction : nil))
        }
        trace.append("serve \(request.transaction) -> \(owner)")
        served[request.transaction] = (true, sequence, connection)
        replies.append(Reply(transaction: request.transaction, ok: true, barrier: sequence))
    }

    /// Another client changes the layout.
    mutating func external() {
        switch Int.random(in: 0..<5, using: &random) {
        case 0:
            guard let surface = owner.allTabs.randomElement(using: &random) else { return }
            let pane = Layout.panes.randomElement(using: &random)!
            if owner.move(surface, to: pane, index: Int.random(in: 0...4, using: &random)) {
                emit(tabChanged(surface, transaction: nil))
            }
        case 1:
            // A close keeps every pane non-empty here (the store's pane
            // removal is not under test).
            let candidates = owner.openPanes.filter { (owner.tabs[$0]?.count ?? 0) > 1 }
            guard let pane = candidates.randomElement(using: &random),
                  let surface = owner.tabs[pane]?.randomElement(using: &random) else { return }
            let index = owner.tabs[pane]!.firstIndex(of: surface)!
            owner.tabs[pane]!.remove(at: index)
            emit(.tabClosed(TabDelta(workspace: 1, screen: 5, pane: pane, surface: surface, index: index, entity: TabSnapshot(surface: surface))))
        case 2:
            // A pane closes with its tabs (tab-closed each, then pane-closed);
            // one pane stays open.
            guard owner.openPanes.count > 1, let pane = owner.openPanes.randomElement(using: &random) else { return }
            while let surface = owner.tabs[pane]?.last {
                let index = owner.tabs[pane]!.count - 1
                owner.tabs[pane]!.removeLast()
                emit(.tabClosed(TabDelta(workspace: 1, screen: 5, pane: pane, surface: surface, index: index, entity: TabSnapshot(surface: surface))))
            }
            owner.tabs[pane] = nil
            emit(.paneClosed(PaneDelta(workspace: 1, screen: 5, pane: pane, index: nil, entity: PaneSnapshot(id: pane))))
        case 3:
            // A closed pane opens again with one new tab.
            guard let pane = Layout.panes.filter({ owner.tabs[$0] == nil }).randomElement(using: &random) else { return }
            let surface = SurfaceID(rawValue: nextSurface)
            nextSurface += 1
            owner.tabs[pane] = [surface]
            emit(.paneAdded(PaneDelta(workspace: 1, screen: 5, pane: pane, index: nil,
                                      entity: PaneSnapshot(id: pane, tabs: [TabSnapshot(surface: surface)]))))
        default:
            guard let pane = owner.openPanes.randomElement(using: &random) else { return }
            let surface = SurfaceID(rawValue: nextSurface)
            nextSurface += 1
            let index = Int.random(in: 0...owner.tabs[pane]!.count, using: &random)
            owner.tabs[pane]!.insert(surface, at: index)
            emit(.tabAdded(TabDelta(workspace: 1, screen: 5, pane: pane, surface: surface, index: index, entity: TabSnapshot(surface: surface))))
        }
        trace.append("external -> \(owner)")
    }

    /// `history` holds what a store that applied every delta up to each
    /// sequence shows: a `tree-changed` carries no delta (the store keeps
    /// its layout and resyncs), so it repeats the previous layout.
    mutating func emit(_ event: DaemonEvent) {
        let previous = history[sequence]
        sequence += 1
        if case .treeChanged = event, let previous {
            history[sequence] = previous
        } else {
            history[sequence] = owner
        }
        events.append(DaemonEventEnvelope(sequence: sequence, event: event))
    }

    func tabChanged(_ surface: SurfaceID, transaction: ClientTransactionID?) -> DaemonEvent {
        let pane = owner.pane(of: surface)!
        return .tabChanged(TabDelta(workspace: 1, screen: 5, pane: pane, surface: surface, index: owner.tabs[pane]!.firstIndex(of: surface),
                                    entity: TabSnapshot(surface: surface), clientTransactionID: transaction))
    }

    // MARK: Checks

    mutating func check(_ log: SettleLog) throws {
        let shown = visible()
        // Conservation.
        try require(shown.allTabs.count == Set(shown.allTabs).count, "duplicated tab in \(shown)")
        try require(Set(shown.allTabs) == Set(confirmed.allTabs), "visible \(shown) lost or gained tabs vs confirmed \(confirmed)")
        // No intent settles twice, and none before the store could know
        // its outcome (its echo, its rejection, or its reply plus every
        // event up to the reply's barrier).
        for transaction in sent {
            let count = log.count(transaction)
            try require(count <= 1, "\(transaction) settled twice")
            // Checked once, with what the store knew when it settled.
            guard count == 1, settledSeen.insert(transaction).inserted else { continue }
            guard let outcome = served[transaction] else { throw failure("\(transaction) settled before the owner served it") }
            let known = outcome.ok
                ? echoesDelivered.contains(transaction) || knownBySnapshot.contains(transaction)
                    || (repliesDelivered.contains(transaction) && outcome.connection == connection && mirrorSequence >= outcome.barrier)
                : repliesDelivered.contains(transaction)
            try require(known, "\(transaction) settled before its outcome reached the store: served \(String(describing: served[transaction])) replied \(repliesDelivered.contains(transaction)) echo \(echoesDelivered.contains(transaction)) snap \(knownBySnapshot.contains(transaction)) await \(awaitingSnapshot.contains(transaction)) conn \(connection) mirror \(mirrorSequence)")
        }
        // An unsettled intent stays visible (the last one per tab wins).
        let open = Set(store.intentLog.entries.map(\.transaction))
        pending.removeAll { !open.contains($0.transaction) }
        var last: [SurfaceID: PaneID] = [:]
        for intent in pending { last[intent.surface] = intent.pane }
        for (surface, pane) in last where confirmed.pane(of: surface) != nil && confirmed.tabs[pane] != nil {
            try require(shown.pane(of: surface) == pane, "pending move of \(surface) to \(pane) not visible in \(shown)")
        }
        // Visible = confirmed + pending intents in order, exactly.
        var expected = confirmed
        for intent in pending { _ = expected.move(intent.surface, to: intent.pane, index: intent.index) }
        try require(shown == expected, "visible \(shown) != confirmed \(confirmed) + intents = \(expected)")
        // Convergence.
        if pending.isEmpty, !resyncPending {
            try require(shown == confirmed, "empty log but visible \(shown) != owner at \(mirrorSequence) \(confirmed)")
            try require(confirmed == history[mirrorSequence], "confirmed \(confirmed) != owner at \(mirrorSequence)")
        }
    }

    func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        guard condition else { throw failure(message()) }
    }

    func failure(_ message: String) -> PropertyFailure {
        let recent = trace.suffix(16).joined(separator: "\n")
        Issue.record(Comment(rawValue: "seed \(seed): \(message)\n\(recent)"))
        return PropertyFailure()
    }

    // MARK: Projection

    func visible() -> Layout {
        var tabs: [PaneID: [SurfaceID]] = [:]
        for pane in Layout.panes { tabs[pane] = store.pane(pane)?.tabs.map(\.surface) }
        return Layout(tabs: tabs)
    }

    func tree(_ layout: Layout) -> DaemonTree {
        var tree = template
        var workspace = tree.workspaces[0]
        let model = workspace.screens[0].panes[0]
        workspace.screens[0].panes = layout.openPanes.map { pane in
            var snapshot = model
            snapshot.id = pane
            snapshot.resourceID = nil
            snapshot.tabGroups = []
            snapshot.tabs = (layout.tabs[pane] ?? []).map { TabSnapshot(surface: $0) }
            return snapshot
        }
        workspace.screens = [workspace.screens[0]]
        tree.workspaces = [workspace]
        return tree
    }
}

private struct PropertyFailure: Error {}

/// Counts settlements per transaction (the store's `onIntentSettled`).
@MainActor private final class SettleLog {
    private var counts: [ClientTransactionID: Int] = [:]
    func record(_ transaction: ClientTransactionID) { counts[transaction, default: 0] += 1 }
    func count(_ transaction: ClientTransactionID) -> Int { counts[transaction] ?? 0 }
}
