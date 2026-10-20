import Foundation
import Testing
@testable import CmuxNextDaemon

/// Cmd-T / Cmd-W spam (tab-spam-race): the store, driven the way the app drives it (a create
/// intent per Cmd-T, a cancel or a close per Cmd-W, the reply handler of `AgentTabStore.open`),
/// against a simulated daemon whose requests, events and replies interleave in every order a
/// real connection allows (events in order, replies in order, the two streams racing each other).
///
/// After every step the person's view holds: the tab count they made, never a tab they closed,
/// no mirror violation. After the daemon drains: the store's records are the daemon's, the intent
/// log is empty and no provisional tab, hidden tab or daemon surface is left behind.
@MainActor
struct TabSpamRaceTests {
    // MARK: Scenarios

    /// 200 Cmd-T, Cmd-W pairs with the daemon making random progress in between.
    @Test(arguments: TabSpamRaceTests.seeds)
    func interleavedNewAndClose(seed: UInt64) {
        var run = SpamRun(seed: seed, rawTabAddedFirst: seed % 2 == 0)
        for _ in 0..<200 {
            run.newTab()
            run.progress(steps: run.random(0...3))
            run.closeSelected()
            run.progress(steps: run.random(0...3))
        }
        run.drain()
        run.expectSettled()
    }

    /// Bursts: T,T,W,W and T,T,T,W,W,W with the daemon behind.
    @Test(arguments: TabSpamRaceTests.seeds)
    func burstsOfNewThenClose(seed: UInt64) {
        var run = SpamRun(seed: seed, rawTabAddedFirst: seed % 2 == 1)
        for _ in 0..<60 {
            let burst = run.random(1...4)
            for _ in 0..<burst { run.newTab(); run.progress(steps: run.random(0...1)) }
            for _ in 0..<burst { run.closeSelected(); run.progress(steps: run.random(0...1)) }
            run.progress(steps: run.random(0...6))
        }
        run.drain()
        run.expectSettled()
    }

    /// Cmd-W always lands while its Cmd-T is pending: before the daemon made the tab, after it
    /// made it but before the reply, after the reply but before the event, or the other way round.
    @Test(arguments: TabSpamRaceTests.seeds)
    func closeDuringPendingCreate(seed: UInt64) {
        var run = SpamRun(seed: seed, rawTabAddedFirst: seed % 3 == 0)
        for _ in 0..<150 {
            run.newTab()
            run.progressCreateOnly(steps: run.random(0...4))
            run.closeSelected()
        }
        run.drain()
        run.expectSettled()
    }

    /// Requests time out under load (the close did commit, its reply never came) and creates fail.
    @Test(arguments: TabSpamRaceTests.seeds)
    func spamUnderDaemonLoad(seed: UInt64) {
        var run = SpamRun(seed: seed, rawTabAddedFirst: seed % 2 == 0, lostReplyRate: 0.15, createFailureRate: 0.05)
        for _ in 0..<200 {
            if run.random(0...2) == 0 { run.closeSelected() } else { run.newTab() }
            run.progress(steps: run.random(0...3))
        }
        run.drain()
        run.expectSettled()
    }

    nonisolated static let seeds: [UInt64] = Array(1...24)
}

// MARK: - The run

/// One spam run: the store, the simulated daemon and what the person expects to see.
@MainActor
private struct SpamRun {
    nonisolated static let pane = PaneID(rawValue: 3)
    nonisolated static let baseSurface = SurfaceID(rawValue: 4)

    let store: DaemonStore
    let daemon: SimulatedDaemon
    var rng: SplitMix

    /// Creates the person made and has not closed, by transaction.
    var liveCreates: [ClientTransactionID] = []
    /// The provisional id each create showed.
    var provisionalIDs: [ClientTransactionID: String] = [:]
    /// Tab ids and surfaces the person closed: none may show again.
    var closedIDs: Set<String> = []
    var closedSurfaces: Set<SurfaceID> = []
    /// The person's tab order in the strip, newest last; Cmd-W closes the last (the selected one).
    var steps = 0
    var failed = false

    init(seed: UInt64, rawTabAddedFirst: Bool, lostReplyRate: Double = 0, createFailureRate: Double = 0) {
        rng = SplitMix(seed: seed)
        store = DaemonStore()
        let base = WorkspaceSnapshot(
            id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "00000000-0000-4000-8000-000000000001"), name: "1",
            screens: [ScreenSnapshot(id: ScreenID(rawValue: 2), active: true, activePane: Self.pane, layout: .leaf(Self.pane),
                                     panes: [PaneSnapshot(id: Self.pane, tabs: [TabSnapshot(surface: Self.baseSurface)])])])
        store.apply(snapshot: DaemonTree(workspaceRevision: 1, workspaces: [base]))
        daemon = SimulatedDaemon(store: store, rawTabAddedFirst: rawTabAddedFirst, lostReplyRate: lostReplyRate,
                                 createFailureRate: createFailureRate, seed: seed &* 0x9E37_79B9)
        // The app's cancelled-creation close (CancelledCreationClose): close-tabs once the surface is known.
        let daemon = daemon
        store.creations.onClose { transaction, surface in daemon.send(.close(surface, cancelled: transaction)) }
    }

    mutating func random(_ range: ClosedRange<Int>) -> Int { rng.next(in: range) }

    // MARK: Person

    /// Cmd-T: a create intent shows the provisional tab now, its request goes out.
    mutating func newTab() {
        let provisional = ProvisionalTab()
        let snapshot = provisional.conversation(ConversationTabRef(agentSession: AgentSessionRef(host: "install:test", hostName: nil)))
        let transaction = ClientTransactionID.generate()
        store.intend(.createTab(pane: Self.pane, provisional: snapshot), transaction: transaction)
        liveCreates.append(transaction)
        provisionalIDs[transaction] = provisional.id
        daemon.send(.create(transaction, snapshot))
        check("Cmd-T tx=\(transaction.rawValue.prefix(8))")
    }

    /// Cmd-W on the selected (newest shown) tab: a pending creation is cancelled, a daemon tab closes.
    mutating func closeSelected() {
        guard let tab = shownTabs().last, tab.surface != Self.baseSurface else { return check("Cmd-W (nothing)") }
        let cancelled = store.creations.cancel(tab: tab.id)
        daemon.log.append("Cmd-W on \(ProvisionalTab.isProvisional(surface: tab.surface) ? "provisional" : "\(tab.surface.rawValue)") cancelled=\(cancelled)")
        if cancelled {
            closedIDs.insert(tab.id)
            if let transaction = provisionalIDs.first(where: { $0.value == tab.id })?.key {
                liveCreates.removeAll { $0 == transaction }
                daemon.state.cancelled.insert(transaction)
            }
        } else {
            closedIDs.insert(tab.id)
            closedSurfaces.insert(tab.surface)
            liveCreates.removeAll { daemon.state.surfaceOf[$0] == tab.surface }
            // `PaneController.close`: one close intent hides it now; the reply settles it.
            let transaction = store.intendClose([tab.surface])
            #expect(transaction != nil, "a shown daemon tab gets a close intent")
            daemon.send(.closeTab(tab.surface, intent: transaction))
        }
        check("Cmd-W")
    }

    // MARK: Daemon

    mutating func progress(steps count: Int) {
        for _ in 0..<count { _ = daemon.step(using: &rng); check("daemon") }
    }

    /// Progress that never runs a close: the create of the newest Cmd-T is in any of its stages.
    mutating func progressCreateOnly(steps count: Int) {
        for _ in 0..<count { _ = daemon.step(using: &rng, closes: false); check("daemon") }
    }

    mutating func drain() {
        var guardSteps = 0
        while daemon.step(using: &rng) { guardSteps += 1; precondition(guardSteps < 100_000); check("drain") }
    }

    // MARK: Invariants

    /// The tabs the strip shows: the store's visible records.
    func shownTabs() -> [TabModel] { store.pane(Self.pane)?.tabs ?? [] }

    mutating func check(_ step: String) {
        steps += 1
        daemon.log.append("\(steps) \(step) shown=\(shownTabs().map { ProvisionalTab.isProvisional(surface: $0.surface) ? "p" : "\($0.surface.rawValue)" })")
        guard !failed else { return }
        var problems: [String] = []
        let shown = shownTabs()
        if !store.mirrorViolations.isEmpty { problems.append("mirror: \(store.mirrorViolations)") }
        for tab in shown {
            if closedIDs.contains(tab.id) { problems.append("a closed tab shows again: \(tab.id)") }
            if closedSurfaces.contains(tab.surface) { problems.append("a closed surface shows again: \(tab.surface.rawValue)") }
            if daemon.state.cancelled.contains(where: { daemon.state.surfaceOf[$0] == tab.surface }) {
                problems.append("a cancelled creation's daemon tab shows: \(tab.surface.rawValue)")
            }
        }
        let surfaces = shown.map(\.surface)
        if Set(surfaces).count != surfaces.count { problems.append("a surface shows twice") }
        // A refused create removes its tab (the person sees it go): it no longer counts.
        let expected = 1 + liveCreates.filter { !daemon.state.refused.contains($0) }.count
        if shown.count != expected { problems.append("the strip shows \(shown.count) tabs, the person made \(expected)") }
        guard !problems.isEmpty else { return }
        failed = true
        Issue.record(Comment(rawValue: "step \(steps) (\(step)): \(problems.joined(separator: "; "))\ntrace:\n"
            + daemon.log.suffix(60).joined(separator: "\n")))
    }

    func expectSettled() {
        guard !failed else { return }
        let records = (store.pane(Self.pane)?.tabs ?? []).map(\.surface)
        #expect(store.pendingIntents.isEmpty, "intents left: \(store.pendingIntents.count)")
        #expect(!records.contains { ProvisionalTab.isProvisional(surface: $0) }, "a provisional tab is left")
        #expect(records == daemon.state.tabs, "the store shows \(records), the daemon has \(daemon.state.tabs)")
        let live = Set(liveCreates.filter { !daemon.state.refused.contains($0) }.compactMap { daemon.state.surfaceOf[$0] })
        #expect(Set(daemon.state.tabs) == live.union([Self.baseSurface]),
                "orphan daemon surfaces: \(Set(daemon.state.tabs).subtracting(live.union([Self.baseSurface])))")
        #expect(store.mirrorViolations.isEmpty, "\(store.mirrorViolations)")
    }
}

// MARK: - The simulated daemon

/// cmux-tui as the store sees it: requests run in order; each emits its events (in order) and one
/// reply (in order); the event stream and the reply stream race. `new-conversation-tab` emits the
/// tab's raw `tab-added` first when `rawTabAddedFirst` (then its transaction echo), and its reply
/// carries the event sequence read after it.
@MainActor
private final class SimulatedDaemon {
    enum Request {
        case create(ClientTransactionID, TabSnapshot)
        /// A close of a cancelled creation's daemon tab (``CancelledCreationClose``).
        case close(SurfaceID, cancelled: ClientTransactionID)
        /// A close of a shown daemon tab, under its close intent (``PaneController.close``).
        case closeTab(SurfaceID, intent: ClientTransactionID?)
    }

    enum Reply {
        case created(ClientTransactionID, SurfaceID, sequence: UInt64)
        case createFailed(ClientTransactionID)
        /// `committed`: the daemon closed it; `replied`: its reply came (else the deadline passed).
        case closed(SurfaceID, cancelled: ClientTransactionID?, intent: ClientTransactionID?, committed: Bool, replied: Bool,
                    sequence: UInt64)
    }

    struct State {
        var tabs: [SurfaceID] = [SpamRun.baseSurface]
        var surfaceOf: [ClientTransactionID: SurfaceID] = [:]
        var cancelled: Set<ClientTransactionID> = []
        /// Creates whose refusal the app has (the provisional tab is gone).
        var refused: Set<ClientTransactionID> = []
        var entities: [SurfaceID: TabSnapshot] = [:]
    }

    let store: DaemonStore
    let rawTabAddedFirst: Bool
    let lostReplyRate: Double
    let createFailureRate: Double
    var state = State()
    var log: [String] = []
    private var requests: [Request] = []
    private var events: [DaemonEventEnvelope] = []
    private var replies: [Reply] = []
    private var sequence: UInt64 = 0
    private var nextSurface: UInt64 = 100
    private var snapshots: UInt64 = 0
    private var faults: SplitMix

    init(store: DaemonStore, rawTabAddedFirst: Bool, lostReplyRate: Double, createFailureRate: Double, seed: UInt64) {
        self.store = store
        self.rawTabAddedFirst = rawTabAddedFirst
        self.lostReplyRate = lostReplyRate
        self.createFailureRate = createFailureRate
        faults = SplitMix(seed: seed)
    }

    func send(_ request: Request) { requests.append(request) }

    static func describe(_ request: Request) -> String {
        switch request {
        case .create(let transaction, _): "create tx=\(transaction.rawValue.prefix(8))"
        case .close(let surface, let cancelled): "close \(surface.rawValue) cancelled=\(cancelled.rawValue.prefix(8))"
        case .closeTab(let surface, _): "close \(surface.rawValue)"
        }
    }

    static func describe(_ reply: Reply) -> String {
        switch reply {
        case .created(let transaction, let surface, let sequence): "created tx=\(transaction.rawValue.prefix(8)) \(surface.rawValue) seq=\(sequence)"
        case .createFailed(let transaction): "create failed tx=\(transaction.rawValue.prefix(8))"
        case .closed(let surface, let cancelled, _, let committed, let replied, let sequence):
            "closed \(surface.rawValue) cancelled=\(cancelled?.rawValue.prefix(8) ?? "-") committed=\(committed) replied=\(replied) seq=\(sequence)"
        }
    }

    static func describe(_ event: DaemonEvent) -> String {
        switch event {
        case .tabAdded(let delta): "tab-added \(delta.surface.rawValue) tx=\(delta.clientTransactionID?.rawValue.prefix(8) ?? "-")"
        case .tabClosed(let delta): "tab-closed \(delta.surface.rawValue)"
        default: "\(event)"
        }
    }

    /// One step: run a request, deliver an event, or deliver a reply (random among those ready).
    /// False when nothing is left.
    @discardableResult
    func step(using rng: inout SplitMix, closes: Bool = true) -> Bool {
        var ready: [Int] = []
        if let next = requests.first, closes || { if case .create = next { true } else { false } }() { ready.append(0) }
        if !events.isEmpty { ready.append(1) }
        if !replies.isEmpty { ready.append(2) }
        guard !ready.isEmpty else { return !requests.isEmpty && closes }
        switch ready[rng.next(in: 0...(ready.count - 1))] {
        case 0: let request = requests.removeFirst(); log.append("run \(Self.describe(request))"); run(request)
        case 1: let event = events.removeFirst(); log.append("event \(event.sequence) \(Self.describe(event.event))"); deliver(event)
        default: let reply = replies.removeFirst(); log.append("reply \(Self.describe(reply))"); deliver(reply)
        }
        return true
    }

    private func emit(_ event: DaemonEvent) {
        sequence += 1
        events.append(DaemonEventEnvelope(sequence: sequence, event: event))
    }

    private func delta(_ surface: SurfaceID, _ entity: TabSnapshot, transaction: ClientTransactionID?) -> TabDelta {
        TabDelta(workspace: WorkspaceHandle(rawValue: 1), screen: ScreenID(rawValue: 2), pane: SpamRun.pane, surface: surface,
                 index: state.tabs.firstIndex(of: surface), entity: entity, clientTransactionID: transaction)
    }

    private func run(_ request: Request) {
        switch request {
        case .create(let transaction, let provisional):
            if faults.chance(createFailureRate) {
                replies.append(.createFailed(transaction))
                return
            }
            let surface = SurfaceID(rawValue: nextSurface)
            nextSurface += 1
            state.tabs.append(surface)
            state.surfaceOf[transaction] = surface
            var entity = TabSnapshot(surface: surface, tabResourceID: ResourceID(rawValue: "tab_\(surface.rawValue)"), kind: .conversation,
                                     title: "about:blank", browserRenderer: "frontend")
            entity.conversation = provisional.conversation
            state.entities[surface] = entity
            if rawTabAddedFirst { emit(.tabAdded(delta(surface, entity, transaction: nil))) }
            emit(.tabAdded(delta(surface, entity, transaction: transaction)))
            replies.append(.created(transaction, surface, sequence: sequence))
        case .close(let surface, let cancelled):
            runClose(surface, cancelled: cancelled, intent: nil)
        case .closeTab(let surface, let intent):
            runClose(surface, cancelled: nil, intent: intent)
        }
    }

    private func runClose(_ surface: SurfaceID, cancelled: ClientTransactionID?, intent: ClientTransactionID?) {
        guard let index = state.tabs.firstIndex(of: surface) else {
            return replies.append(.closed(surface, cancelled: cancelled, intent: intent, committed: false, replied: true, sequence: sequence))
        }
        let entity = state.entities[surface] ?? TabSnapshot(surface: surface)
        let closed = delta(surface, entity, transaction: nil)
        state.tabs.remove(at: index)
        state.entities[surface] = nil
        emit(.tabClosed(closed))
        // Under load the close commits and its reply is lost (the request's deadline passes).
        replies.append(.closed(surface, cancelled: cancelled, intent: intent, committed: true,
                               replied: !faults.chance(lostReplyRate), sequence: sequence))
    }

    /// `refresh()`: a snapshot of everything the daemon did so far, its barrier the last event's sequence.
    private func refresh() {
        let tabs = state.tabs.map { state.entities[$0] ?? TabSnapshot(surface: $0) }
        let workspace = WorkspaceSnapshot(
            id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "00000000-0000-4000-8000-000000000001"), name: "1",
            screens: [ScreenSnapshot(id: ScreenID(rawValue: 2), active: true, activePane: SpamRun.pane, layout: .leaf(SpamRun.pane),
                                     panes: [PaneSnapshot(id: SpamRun.pane, tabs: tabs)])])
        snapshots += 1
        // The resync holds the inbox (`DaemonStore.resync`): the events the snapshot covers are
        // drained right after it, in its turn, superseded but still settling their echoes.
        store.apply(snapshot: DaemonTree(workspaceRevision: 1 + snapshots, workspaces: [workspace]))
        store.snapshotBarrier = max(store.snapshotBarrier, sequence)
        store.advanceAppliedSequence(to: sequence)
        let covered = events.filter { $0.sequence <= sequence }
        events.removeAll { $0.sequence <= sequence }
        if !covered.isEmpty { _ = store.apply(batch: covered) }
        log.append("snapshot at \(sequence) (drained \(covered.count) covered events)")
    }

    private func deliver(_ envelope: DaemonEventEnvelope) {
        _ = store.apply(batch: [envelope])
    }

    /// The app's reply handlers: `AgentTabStore.open`'s task for a create, `CancelledCreationClose`
    /// and `PaneController.close` for a close.
    private func deliver(_ reply: Reply) {
        switch reply {
        case .created(let transaction, let surface, let sequence):
            ProvisionalTab.created(transaction, surface: surface, in: store)
            store.noteSettled(transaction, at: sequence)
        case .createFailed(let transaction):
            state.refused.insert(transaction)
            store.rejectIntent(transaction)
        case .closed(_, let cancelled?, _, let committed, let replied, _):
            // `CancelledCreationClose`: a failure shows what the daemon kept; a lost reply
            // refreshes and sends the close again while the records still hold the tab.
            if !replied {
                refresh()
                store.creations.closeTimedOut(cancelled)
            } else if !committed {
                store.rejectIntent(cancelled)
            }
        case .closed(_, nil, let intent, let committed, let replied, let sequence):
            // `PaneController.close`.
            guard let intent else { return }
            if !replied {
                store.noteSettledAtNextSnapshot(intent)
                refresh()
            } else if !committed {
                store.rejectIntent(intent)
            } else {
                store.noteSettled(intent, at: sequence)
            }
        }
    }
}

/// A seeded generator, so a failing seed replays exactly.
private struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }

    mutating func chance(_ rate: Double) -> Bool {
        rate > 0 && Double(next() % 1_000_000) / 1_000_000 < rate
    }
}
