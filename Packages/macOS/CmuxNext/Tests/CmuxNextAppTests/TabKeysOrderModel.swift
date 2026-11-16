@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import os

/// What a pane's tab list and selection must be after each New Tab and Close Tab key. A pure value written from the
/// words of the close selection rule, not a call of the product's functions: the fuzz compares it with what
/// `NewTabSlot.target`, `TabSelectionMemory.resolve` and `TabCloseSelection.successor` gave the strip.
///
/// - A new tab goes directly right of the selected tab, the selected tab is its opener, and it is selected.
/// - A close of the selected tab selects, first match: a tab it opened (the first one after it, else the nearest
///   before it); a tab of the same opener (the same search); its opener; the next tab, the previous tab only when it
///   was the last.
/// - A close of a tab that is not selected changes no selection.
/// - A tab whose opener is gone has no opener.
///
/// The keys of the fuzz select no tab by a gesture, so no opener is forgotten for another cause.
nonisolated struct TabKeysOracle: Sendable, Equatable {
    private(set) var tabs: [String]
    private(set) var selected: String?
    private var opener: [String: String] = [:]

    init(tabs: [String], selected: String?) {
        self.tabs = tabs
        self.selected = selected
    }

    /// New Tab: `name` opens directly right of the selected tab and is selected.
    mutating func open(_ name: String) {
        let place = selected.flatMap { tabs.firstIndex(of: $0) }.map { $0 + 1 } ?? tabs.count
        tabs.insert(name, at: place)
        if let selected { opener[name] = selected }
        selected = name
    }

    /// Close Tab on `name`.
    mutating func close(_ name: String) {
        guard let index = tabs.firstIndex(of: name) else {
            // Only after `take`: the strip selected a tab that it did not list. No rule gives the next selection.
            if selected == name { selected = nil }
            opener[name] = nil
            opener = opener.filter { $0.value != name }
            return
        }
        let next = name == selected ? successor(of: name, at: index) : selected
        tabs.remove(at: index)
        opener[name] = nil
        opener = opener.filter { $0.value != name }
        selected = next
    }

    /// After a recorded difference: the oracle goes on from the strip's list and selection. Each opener that the keys
    /// made stays, also for a tab that the strip does not list at this time.
    mutating func take(tabs: [String], selected: String?) {
        self.tabs = tabs
        self.selected = selected
    }

    private func successor(of name: String, at index: Int) -> String? {
        func nearest(_ matches: (String) -> Bool) -> String? {
            tabs[(index + 1)...].first(where: matches) ?? tabs[..<index].last(where: matches)
        }
        if let opened = nearest({ opener[$0] == name }) { return opened }
        if let parent = opener[name] {
            return nearest { opener[$0] == parent } ?? parent
        }
        if index + 1 < tabs.count { return tabs[index + 1] }
        return index > 0 ? tabs[index - 1] : nil
    }
}

/// SplitMix64: the fuzz's only source of choice, so a seed gives the same keys and the same deliveries each run.
nonisolated struct TabKeysRandom: Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(in range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
}

/// A model of the session daemon for one pane, as the app's requests see it. A request runs when it arrives: a create
/// puts the tab at the END of the pane and makes one `tab-added` with the request's transaction; `move-tab` moves it
/// by the daemon's index rule and makes one `tree-changed` and then one `tab-changed` with the tab's new index;
/// `close-surface` makes one `tab-closed` and then one `tree-changed`. A `tree-changed` carries no transaction: the
/// app answers it with a read of the whole tree (``snapshot(of:)``). The model keeps each event and each reply until
/// the test hands it over: events in their sequence order, replies in ANY order, with one limit: the reply of a create
/// goes before a tree that holds its tab (``createReplyBeforeTree``).
///
/// Not modelled: selection events, the daemon's own selected tab (a tree gives the fixture's value), and each request
/// other than these (it is refused as not connected and its command is kept in ``refused``).
@MainActor final class TabKeysModelDaemon {
    nonisolated struct Refusal: Error { let reason: String }

    /// The connection's answerer for the close and the move requests (``DaemonRequestAnswering``). The connection calls
    /// it on its own executor; the model runs on the main actor.
    nonisolated final class Answerer: DaemonRequestAnswering {
        private let model: TabKeysModelDaemon
        private let emitted: OSAllocatedUnfairLock<UInt64>

        init(_ model: TabKeysModelDaemon) {
            self.model = model
            emitted = model.emitted
        }

        var eventSequence: UInt64? { emitted.withLock { $0 } }

        func receive(_ request: any DaemonRequest, reply: CheckedContinuation<Data, any Error>) {
            let model = model
            Task { @MainActor in model.arrived(request, reply: reply) }
        }
    }

    let workspace: WorkspaceHandle
    let screen: ScreenID
    let pane: PaneID
    /// The newest event sequence made, read by the connection off the main actor.
    nonisolated let emitted = OSAllocatedUnfairLock(initialState: UInt64(0))
    /// The pane's tabs at the daemon, in order.
    private(set) var tabs: [SurfaceID]
    /// The surface of the n-th create request, in arrival order.
    private(set) var creates: [SurfaceID] = []
    /// The commands the model does not answer, in arrival order.
    private(set) var refused: [String] = []
    /// A request for a tab that the daemon never held.
    private(set) var faults: [String] = []
    /// A request for a tab that the daemon closed before: it is refused, as the daemon refuses it.
    private(set) var stale: [String] = []
    private var closed: Set<SurfaceID> = []
    private var names: [SurfaceID: String] = [:]
    private var entities: [SurfaceID: TabSnapshot] = [:]
    private var events: [DaemonEventEnvelope] = []
    private var parked: [(label: String, created: SurfaceID?, deliver: @MainActor () -> Void)] = []
    private var nextSurface: UInt64 = 100_000

    /// `tabs`: the pane's tabs at the start, named `s0`, `s1`, ... A created tab is named `t1`, `t2`, ... in the order
    /// of the create requests.
    init(workspace: WorkspaceHandle, screen: ScreenID, pane: PaneID, tabs: [SurfaceID]) {
        self.workspace = workspace
        self.screen = screen
        self.pane = pane
        self.tabs = tabs
        for (index, surface) in tabs.enumerated() { names[surface] = "s\(index)" }
    }

    func name(_ surface: SurfaceID) -> String { names[surface] ?? "surface \(surface.rawValue)" }
    var pendingEvents: Int { events.count }
    var pendingReplies: Int { parked.count }

    /// The first waiting reply of a create whose tab the daemon holds now; nil when none waits. The daemon runs the
    /// requests of one connection in the order of their arrival, and it writes the reply of a page's create before it
    /// runs the next request. So the app has that reply before a tree that holds the tab: the test hands it over first.
    var createReplyBeforeTree: Int? {
        parked.firstIndex { reply in
            guard let created = reply.created else { return false }
            return tabs.contains(created)
        }
    }

    // MARK: Requests

    /// The app's create of a New Tab page: the tab is at the end of the pane at once; the reply waits.
    func create(record: AgentSessionRef, transaction: ClientTransactionID) async throws -> (created: AgentTabCreated, sequence: UInt64?) {
        let surface = SurfaceID(rawValue: nextSurface)
        nextSurface += 1
        let key = "tab_\(surface.rawValue)"
        var entity = TabSnapshot(surface: surface, tabResourceID: ResourceID(rawValue: key), kind: .conversation, title: "about:blank",
                                 browserRenderer: "frontend")
        entity.conversation = ConversationTabRef(agentSession: record)
        entities[surface] = entity
        creates.append(surface)
        let name = "t\(creates.count)"
        names[surface] = name
        tabs.append(surface)
        emit(.tabAdded(delta(surface, entity, index: tabs.count - 1, transaction: transaction)))
        let emitted = emitted
        let reply: (created: AgentTabCreated, sequence: UInt64?) = try await withCheckedThrowingContinuation { continuation in
            parked.append((label: "create \(name)", created: surface, deliver: {
                // The write barrier of the reply: each event made before it leaves the daemon.
                continuation.resume(returning: (created: AgentTabCreated(key: key, surface: surface), sequence: emitted.withLock { $0 }))
            }))
        }
        return reply
    }

    /// A request of the connection (``Answerer``).
    func arrived(_ request: any DaemonRequest, reply: CheckedContinuation<Data, any Error>) {
        switch request {
        case let one as CloseTabRequest:
            answer("close \(name(one.surface))", reply, close(one.surface) ? "{}" : nil)
        case let many as CloseTabsRequest:
            let closed = many.surfaces.map { close($0) }
            answer("close \(many.surfaces.map { name($0) }.joined(separator: " "))", reply, closed.contains(false) ? nil : "{}")
        case let moved as MoveTabRequest:
            answer("move \(name(moved.surface)) to \(moved.index)", reply, move(moved))
        default:
            refused.append(type(of: request).command)
            reply.resume(throwing: DaemonError.notConnected)
        }
    }

    private func answer(_ label: String, _ reply: CheckedContinuation<Data, any Error>, _ json: String?) {
        parked.append((label: label, created: nil, deliver: {
            if let json { reply.resume(returning: Data(json.utf8)) } else { reply.resume(throwing: Refusal(reason: label)) }
        }))
    }

    private func close(_ surface: SurfaceID) -> Bool {
        guard let index = tabs.firstIndex(of: surface), let entity = entities[surface] else {
            unknown("a close of \(name(surface))", surface)
            return false
        }
        let gone = delta(surface, entity, index: index, transaction: nil)
        tabs.remove(at: index)
        entities[surface] = nil
        closed.insert(surface)
        emit(.tabClosed(gone))
        emit(.treeChanged(transaction: nil))
        return true
    }

    /// The daemon's `move-tab`: the index counts the list before the move, so a move to the right lands one lower.
    private func move(_ move: MoveTabRequest) -> String? {
        guard move.pane == pane, let old = tabs.firstIndex(of: move.surface), let entity = entities[move.surface] else {
            unknown("a move of \(name(move.surface))", move.surface)
            return nil
        }
        let place = max(0, min(move.index > old ? move.index - 1 : move.index, tabs.count - 1))
        guard place != old else { return #"{"moved":false,"undoable":false}"# }
        tabs.remove(at: old)
        tabs.insert(move.surface, at: place)
        emit(.treeChanged(transaction: nil))
        emit(.tabChanged(delta(move.surface, entity, index: place, transaction: move.transaction)))
        return #"{"moved":true,"undoable":false}"#
    }

    private func unknown(_ what: String, _ surface: SurfaceID) {
        if closed.contains(surface) { stale.append(what) } else { faults.append("\(what), which the daemon never made") }
    }

    private func delta(_ surface: SurfaceID, _ entity: TabSnapshot, index: Int, transaction: ClientTransactionID?) -> TabDelta {
        TabDelta(workspace: workspace, screen: screen, pane: pane, surface: surface, index: index, entity: entity,
                 clientTransactionID: transaction)
    }

    private func emit(_ event: DaemonEvent) {
        let sequence = emitted.withLock { state -> UInt64 in
            state += 1
            return state
        }
        events.append(DaemonEventEnvelope(sequence: sequence, event: event))
    }

    // MARK: Deliveries

    /// The next `count` events, in sequence order: the test applies them to the store as one batch.
    func takeEvents(_ count: Int) -> [DaemonEventEnvelope] {
        let batch = Array(events.prefix(count))
        events.removeFirst(batch.count)
        return batch
    }

    /// The whole tree as the daemon holds it now, and the newest event sequence it holds: `base` (the tree the
    /// session started from) with this pane's tabs replaced. Nil: `base` has no such pane, or the model holds a tab with
    /// no entity.
    func snapshot(of base: DaemonTree) -> (tree: DaemonTree, barrier: UInt64)? {
        var tree = base
        for workspace in tree.workspaces.indices {
            for screen in tree.workspaces[workspace].screens.indices {
                for index in tree.workspaces[workspace].screens[screen].panes.indices
                where tree.workspaces[workspace].screens[screen].panes[index].id == pane {
                    let start = Dictionary(tree.workspaces[workspace].screens[screen].panes[index].tabs.map { ($0.surface, $0) },
                                           uniquingKeysWith: { first, _ in first })
                    let held = tabs.compactMap { entities[$0] ?? start[$0] }
                    guard held.count == tabs.count else { return nil }
                    tree.workspaces[workspace].screens[screen].panes[index].tabs = held
                    return (tree: tree, barrier: emitted.withLock { $0 })
                }
            }
        }
        return nil
    }

    /// Gives the reply at `index` of the waiting replies back to the app; returns what it answers.
    func deliverReply(_ index: Int) -> String {
        let reply = parked.remove(at: index)
        reply.deliver()
        return reply.label
    }
}
