import Foundation
import Testing
@testable import CmuxNextDaemon

/// The reference owner of `IntentLogPropertyTests`: serves requests, lets
/// other clients change things, emits cmux-tui's events, and checks the
/// store against it.
extension IntentWorld {
    static let groupPane: PaneID = 30
    static let groupTabs: [SurfaceID] = [900, 901]

    // MARK: Owner

    mutating func serve() {
        guard !outbox.isEmpty else { return }
        let request = outbox.removeFirst()
        let roll = Int.random(in: 0..<100, using: &random)
        guard roll >= 8, owner.accepts(request.intent) else {
            trace.append("reject \(request.transaction)")
            served[request.transaction] = (false, sequence, connection)
            replies.append(Reply(transaction: request.transaction, ok: false, barrier: sequence))
            return
        }
        if owner.apply(request.intent) { emitChange(request.intent, transaction: request.transaction) }
        trace.append("serve \(request.transaction) -> \(owner)")
        served[request.transaction] = (true, sequence, connection)
        replies.append(Reply(transaction: request.transaction, ok: true, barrier: sequence))
    }

    /// cmux-tui's events for an applied change. Only move-tab carries the
    /// client's transaction (the others take none); a collapse is reported
    /// as `tree-changed` only.
    mutating func emitChange(_ intent: Intent, transaction: ClientTransactionID?) {
        switch intent {
        case .moveTab(let surface, _, _):
            if Int.random(in: 0..<4, using: &random) == 0 { emit(.treeChanged(transaction: nil)) }
            let echo = Int.random(in: 0..<5, using: &random) != 0
            emit(tabChanged(surface, transaction: echo ? transaction : nil))
        case .renameTab(let surface, _), .setTabPinned(let surface, _):
            emit(tabChanged(surface, transaction: nil))
        case .renameWorkspace(let key, _):
            emit(.workspaceRenamed(workspaceDelta(key, index: nil)))
        case .moveWorkspace(let key, _), .setWorkspaceGroup(let key, _), .placeWorkspace(let key, _, _):
            if Int.random(in: 0..<4, using: &random) == 0 { emit(.treeChanged(transaction: nil)) }
            emit(.workspaceMoved(workspaceDelta(key, index: owner.index(of: key))))
        case .setWorkspaceGroupCollapsed, .setTabGroupCollapsed, .setRowHeights, .createTab:
            emit(.treeChanged(transaction: nil))
        }
    }

    /// Another client changes the state.
    mutating func external() {
        switch Int.random(in: 0..<7, using: &random) {
        case 0:
            // Any change another client can make with the same commands.
            guard let intent = randomIntent(in: owner), owner.apply(intent) else { return }
            emitChange(intent, transaction: nil)
        case 1:
            // A close keeps every pane non-empty here (the store's pane
            // removal is not under test).
            let candidates = owner.layout.openPanes.filter { (owner.layout.tabs[$0]?.count ?? 0) > 1 }
            guard let pane = candidates.randomElement(using: &random),
                  let surface = owner.layout.tabs[pane]?.randomElement(using: &random) else { return }
            let index = owner.layout.tabs[pane]!.firstIndex(of: surface)!
            owner.layout.tabs[pane]!.remove(at: index)
            owner.meta[surface] = nil
            emit(.tabClosed(TabDelta(workspace: 1, screen: 5, pane: pane, surface: surface, index: index, entity: TabSnapshot(surface: surface))))
        case 2:
            // A pane closes with its tabs (tab-closed each, then pane-closed);
            // one pane stays open.
            guard owner.layout.openPanes.count > 1, let pane = owner.layout.openPanes.randomElement(using: &random) else { return }
            while let surface = owner.layout.tabs[pane]?.last {
                let index = owner.layout.tabs[pane]!.count - 1
                owner.layout.tabs[pane]!.removeLast()
                owner.meta[surface] = nil
                emit(.tabClosed(TabDelta(workspace: 1, screen: 5, pane: pane, surface: surface, index: index, entity: TabSnapshot(surface: surface))))
            }
            owner.layout.tabs[pane] = nil
            emit(.paneClosed(PaneDelta(workspace: 1, screen: 5, pane: pane, index: nil, entity: PaneSnapshot(id: pane))))
        case 3:
            // A closed pane opens again with one new tab.
            guard let pane = RefLayout.panes.filter({ owner.layout.tabs[$0] == nil }).randomElement(using: &random) else { return }
            let surface = newSurface()
            owner.layout.tabs[pane] = [surface]
            emit(.paneAdded(PaneDelta(workspace: 1, screen: 5, pane: pane, index: nil,
                                      entity: PaneSnapshot(id: pane, tabs: [tabSnapshot(surface)]))))
        case 4:
            guard let pane = owner.layout.openPanes.randomElement(using: &random) else { return }
            let surface = newSurface()
            let index = Int.random(in: 0...owner.layout.tabs[pane]!.count, using: &random)
            owner.layout.tabs[pane]!.insert(surface, at: index)
            emit(.tabAdded(TabDelta(workspace: 1, screen: 5, pane: pane, surface: surface, index: index, entity: tabSnapshot(surface))))
        default:
            guard let surface = owner.layout.allTabs.randomElement(using: &random) else { return }
            let pane = RefLayout.panes.randomElement(using: &random)!
            if owner.layout.move(surface, to: pane, index: Int.random(in: 0...4, using: &random)) {
                emit(tabChanged(surface, transaction: nil))
            }
        }
        trace.append("external -> \(owner)")
    }

    private mutating func newSurface() -> SurfaceID {
        let surface = SurfaceID(rawValue: nextSurface)
        nextSurface += 1
        owner.meta[surface] = RefTabMeta()
        return surface
    }

    /// `history` holds what a store that applied every delta up to each
    /// sequence shows: a `tree-changed` carries no delta (the store keeps
    /// its state and resyncs), so it repeats the previous state.
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

    func tabSnapshot(_ surface: SurfaceID) -> TabSnapshot {
        let meta = owner.meta[surface] ?? RefTabMeta()
        return TabSnapshot(surface: surface, name: meta.name, pinned: meta.pinned)
    }

    func tabChanged(_ surface: SurfaceID, transaction: ClientTransactionID?) -> DaemonEvent {
        let pane = owner.layout.pane(of: surface)!
        return .tabChanged(TabDelta(workspace: 1, screen: 5, pane: pane, surface: surface, index: owner.layout.tabs[pane]!.firstIndex(of: surface),
                                    entity: tabSnapshot(surface), clientTransactionID: transaction))
    }

    /// A workspace delta (the next revision) whose entity is the workspace
    /// as the owner holds it now.
    mutating func workspaceDelta(_ key: WorkspaceKey, index: Int?) -> WorkspaceDelta {
        revision += 1
        let entity = tree(owner).workspaces.first { $0.key == key }!
        return WorkspaceDelta(workspace: entity.id, index: index, entity: entity, workspaceRevision: revision)
    }

    /// The tab group's collapse carried by a workspace delta of the
    /// workspace holding it (nil for any other event).
    static func tabGroupCollapse(in event: DaemonEvent) -> Bool? {
        switch event {
        case .workspaceAdded(let delta), .workspaceRenamed(let delta), .workspaceChanged(let delta), .workspaceMoved(let delta):
            delta.entity.screens.flatMap(\.panes).first { $0.id == groupPane }?.tabGroups.first?.collapsed
        default: nil
        }
    }

    // MARK: Checks

    mutating func check(_ log: IntentSettleLog) throws {
        let shown = visible()
        // Conservation.
        try require(shown.layout.allTabs.count == Set(shown.layout.allTabs).count, "duplicated tab in \(shown)")
        try require(Set(shown.layout.allTabs) == Set(confirmed.layout.allTabs), "visible \(shown) lost or gained tabs vs confirmed \(confirmed)")
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
            try require(known, "\(transaction) settled before its outcome reached the store: served \(String(describing: served[transaction])) replied \(repliesDelivered.contains(transaction)) echo \(echoesDelivered.contains(transaction)) snap \(knownBySnapshot.contains(transaction)) conn \(connection) mirror \(mirrorSequence)")
        }
        // An unsettled move stays visible (the last one per tab wins).
        let open = Set(store.intentLog.entries.map(\.transaction))
        pending.removeAll { !open.contains($0.transaction) }
        var last: [SurfaceID: PaneID] = [:]
        for case (_, .moveTab(let surface, let pane, _)) in pending { last[surface] = pane }
        for (surface, pane) in last where confirmed.layout.pane(of: surface) != nil && confirmed.layout.tabs[pane] != nil {
            try require(shown.layout.pane(of: surface) == pane, "pending move of \(surface) to \(pane) not visible in \(shown)")
        }
        // Visible = confirmed + pending intents in order, exactly.
        var expected = confirmed
        for (_, intent) in pending { _ = expected.apply(intent) }
        try require(shown == expected, "visible \(shown) != confirmed \(confirmed) + intents = \(expected)")
        // Convergence.
        if pending.isEmpty, !resyncPending {
            try require(shown == confirmed, "empty log but visible \(shown) != confirmed \(confirmed)")
            var atSequence = history[mirrorSequence]!
            atSequence.groupCollapsed = confirmed.groupCollapsed
            atSequence.tabGroupCollapsed = confirmed.tabGroupCollapsed
            try require(confirmed == atSequence, "confirmed \(confirmed) != owner at \(mirrorSequence) \(atSequence)")
        }
    }

    // MARK: Projection

    func visible() -> RefState {
        var tabs: [PaneID: [SurfaceID]] = [:]
        var meta: [SurfaceID: RefTabMeta] = [:]
        for pane in RefLayout.panes {
            guard let model = store.pane(pane) else { continue }
            tabs[pane] = model.tabs.map(\.surface)
            for tab in model.tabs { meta[tab.surface] = RefTabMeta(name: tab.name, pinned: tab.pinned) }
        }
        let workspaces = store.workspaces.map { RefWorkspace(key: $0.key!, handle: $0.handle, name: $0.name, group: $0.group) }
        var collapsed: [WorkspaceGroupID: Bool] = [:]
        for id in RefState.groups { collapsed[id] = store.group(id)?.collapsed }
        return RefState(layout: RefLayout(tabs: tabs), meta: meta, workspaces: workspaces, groupCollapsed: collapsed,
                        tabGroupCollapsed: store.tabGroup(RefState.tabGroup)?.collapsed ?? false)
    }

    /// The owner's tree: workspace 1 holds the panes under test and a
    /// fourth pane with the tab group; the other workspaces have no screens.
    func tree(_ state: RefState) -> DaemonTree {
        var tree = template
        tree.workspaceRevision = revision
        tree.groups = RefState.groups.enumerated().map { index, id in
            WorkspaceGroupSnapshot(id: id, name: id.rawValue, collapsed: state.groupCollapsed[id] ?? false, index: index)
        }
        var main = tree.workspaces[0]
        let model = main.screens[0].panes[0]
        let pane = { (id: PaneID, tabs: [TabSnapshot]) in
            var snapshot = model
            snapshot.id = id
            snapshot.resourceID = nil
            snapshot.tabGroups = []
            snapshot.tabs = tabs
            return snapshot
        }
        var grouped = pane(Self.groupPane, Self.groupTabs.map { surface in
            var tab = TabSnapshot(surface: surface)
            tab.tabGroup = RefState.tabGroup
            return tab
        })
        grouped.tabGroups = [TabGroupSnapshot(id: RefState.tabGroup, name: "T", collapsed: state.tabGroupCollapsed,
                                              surfaces: Self.groupTabs, pane: Self.groupPane)]
        main.screens[0].panes = state.layout.openPanes.map { id in
            pane(id, (state.layout.tabs[id] ?? []).map { TabSnapshot(surface: $0, name: state.meta[$0]?.name, pinned: state.meta[$0]?.pinned ?? false) })
        } + [grouped]
        main.screens = [main.screens[0]]
        let empty = tree.workspaces[1]
        tree.workspaces = state.workspaces.map { workspace in
            var snapshot = workspace.key == RefState.main ? main : empty
            snapshot.id = workspace.handle
            snapshot.key = workspace.key
            if workspace.key != RefState.main { snapshot.resourceID = nil }
            snapshot.name = workspace.name
            snapshot.group = workspace.group
            return snapshot
        }
        return tree
    }
}
