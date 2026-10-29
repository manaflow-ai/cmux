import Foundation
import CmuxMobileModel

/// Applies daemon workspace events off the main actor. The daemon's raw rows
/// remain JSON because the iOS projection intentionally flattens a different
/// subset of the desktop tree. A delta decodes only its affected row and then
/// replaces that row in the published `DaemonTree`.
public actor WorkspaceProjection {
    public struct Update: Sendable {
        public var tree: DaemonTree
        public var changedWorkspaceIDs: Set<String>
        /// True when membership/order changed and callers should refresh the
        /// sidebar's structure as well as the changed rows.
        public var topology: Bool

        public init(tree: DaemonTree, changedWorkspaceIDs: Set<String>, topology: Bool = false) {
            self.tree = tree
            self.changedWorkspaceIDs = changedWorkspaceIDs
            self.topology = topology
        }
    }

    public enum ProjectionError: Error, Equatable, Sendable {
        /// The event cannot be safely applied (missing entity, unknown handle,
        /// or a revision gap); caller must issue a full list-workspaces.
        case needsSnapshot
        case malformedSnapshot
    }

    fileprivate struct Row {
        var value: [String: Any]
        var key: String
        var handle: Int?

        var isHome: Bool { value["kind"] as? String == "home" }
    }

    private struct RowMetadata {
        var tabs: Set<String>
        var surfaces: Set<Int>
        var groups: Set<String>
    }

    private var rows: [Row] = []
    private var tree: DaemonTree?
    private var macID = ""
    private var agents = AgentStates()
    private var activity: [Int: Date] = [:]
    private var revision: Int?
    private var registryID: String?
    private var arrangement: SidebarArrangement?
    private var metadata: [String: RowMetadata] = [:]
    private var removedMetadata: [String: RowMetadata] = [:]
    private var surfaceRows: [Int: Int] = [:]

    public init() {}

    /// Replaces the raw snapshot after a reconnect or an event gap. Parsing
    /// happens on this actor's executor, never on the main actor.
    @discardableResult
    public func reset(snapshot: Data, macID: String, previous: [Workspace] = [], agents: AgentStates = AgentStates(),
                      activity: [Int: Date] = [:], arrangement: SidebarArrangement? = nil) throws -> DaemonTree {
        guard let object = try? JSONSerialization.jsonObject(with: snapshot) as? [String: Any] else {
            throw ProjectionError.malformedSnapshot
        }
        let data = object["data"] as? [String: Any] ?? object
        guard let values = data["workspaces"] as? [Any] else { throw ProjectionError.malformedSnapshot }
        let nextRows = values.compactMap { value -> Row? in
            guard let row = value as? [String: Any] else { return nil }
            return Row(value: row, key: Self.rowKey(row), handle: row["id"] as? Int)
        }
        guard nextRows.count == values.count,
              nextRows.allSatisfy({ !$0.key.isEmpty }),
              Set(nextRows.map(\.key)).count == nextRows.count else { throw ProjectionError.malformedSnapshot }
        var parsed = try DaemonTree(reply: snapshot, macID: macID, previous: previous, agents: agents, activity: activity)
        parsed.apply(arrangement)
        rows = nextRows
        metadata = Dictionary(uniqueKeysWithValues: rows.map { ($0.key, Self.metadata(for: $0.value)) })
        removedMetadata = [:]
        rebuildSurfaceIndex()
        self.macID = macID
        self.agents = agents
        self.activity = activity
        self.arrangement = arrangement
        revision = data["workspace_revision"] as? Int
        registryID = data["registry_id"] as? String
        self.tree = parsed
        return parsed
    }

    /// Applies one typed tree/title/agent event. `nil` means the event changes
    /// no workspace row (for example a replayed add).
    public func apply(_ event: DaemonEvent, agents: AgentStates, activity: [Int: Date]) throws -> Update? {
        guard tree != nil else { throw ProjectionError.needsSnapshot }
        let oldAgents = self.agents
        let oldActivity = self.activity
        self.agents = agents
        self.activity = activity
        do {
            switch event {
            case .delta(let delta):
                let changed = try apply(delta)
                return try publish(changed: changed.ids, topology: changed.topology)
            case .titleChanged(let surface, let title):
                guard let rowIndex = rowIndex(surface: surface) else { throw ProjectionError.needsSnapshot }
                rows[rowIndex].setTitle(surface: surface, title: title)
                let id = try rowID(at: rowIndex)
                return try publish(changed: [id], topology: false)
            case .agentChanged(let surface, _, _, _, _):
                guard let rowIndex = rowIndex(surface: surface) else { throw ProjectionError.needsSnapshot }
                let id = try rowID(at: rowIndex)
                return try publish(changed: [id], topology: false)
            case .notification:
                // The event carries text, but unread markers live in the snapshot.
                throw ProjectionError.needsSnapshot
            case .other:
                return nil
            case .treeChanged, .resubscribe:
                throw ProjectionError.needsSnapshot
            }
        } catch {
            self.agents = oldAgents
            self.activity = oldActivity
            throw error
        }
    }

    /// Updates all rows touched by an agent roster or pending-question change.
    /// This lets setPending and list-agents update only the affected rows.
    public func updateAgents(agents: AgentStates, activity: [Int: Date]) throws -> Update? {
        let old = self.agents
        self.agents = agents
        self.activity = activity
        var surfaces = Set<Int>()
        for surface in Set(old.bySurface.keys).union(agents.bySurface.keys)
            where old.bySurface[surface] != agents.bySurface[surface] { surfaces.insert(surface) }
        if old.pending != agents.pending || old.waitingFor != agents.waitingFor {
            let sessions = Set(old.pending.keys).union(agents.pending.keys).union(old.waitingFor.keys).union(agents.waitingFor.keys)
            for row in rows {
                for tab in Self.tabs(row.value) {
                    guard let surface = tab["surface"] as? Int,
                          let session = Self.agentSession(tab), sessions.contains(session) else { continue }
                    surfaces.insert(surface)
                }
            }
        }
        guard !surfaces.isEmpty else { return nil }
        var IDs = Set<String>()
        for surface in surfaces {
            guard let index = rowIndex(surface: surface) else { continue }
            IDs.insert(try rowID(at: index))
        }
        guard !IDs.isEmpty else { return nil }
        return try publish(changed: IDs, topology: false)
    }

    // MARK: Delta patching

    private func apply(_ delta: DaemonTreeDelta) throws -> (ids: Set<String>, topology: Bool) {
        if let eventRegistry = delta.registryID, let registryID, eventRegistry != registryID {
            throw ProjectionError.needsSnapshot
        }
        var nextRevision: Int?
        if delta.kind.isWorkspace, let next = delta.workspaceRevision {
            if let current = revision {
                if next <= current { return ([], false) }
                if next != current + 1 { throw ProjectionError.needsSnapshot }
            }
            nextRevision = next
        }
        if delta.kind.isWorkspace {
            let result = try patchWorkspace(delta)
            if let nextRevision { revision = nextRevision }
            return result
        }
        guard let workspaceIndex = rowIndex(workspace: delta.workspace, key: delta.workspaceKey) else {
            // A replayed close can arrive after its original close was applied.
            // There is no state to recover for it.
            if delta.kind.isClose { return ([], false) }
            throw ProjectionError.needsSnapshot
        }
        guard let entity = delta.entity.flatMap(Self.object) else {
            // Close events need no entity; all other events do.
            guard delta.kind.isClose else { throw ProjectionError.needsSnapshot }
            let id = try rowID(at: workspaceIndex)
            let changed = try patchNested(delta, in: &rows[workspaceIndex].value, entity: nil)
            if changed { removedMetadata[rows[workspaceIndex].key] = metadata[rows[workspaceIndex].key] }
            refreshMetadata(for: rows[workspaceIndex].key, at: workspaceIndex)
            if !changed { return ([], false) }
            return (Set([id]), changed)
        }
        let id = try rowID(at: workspaceIndex)
        let changed = try patchNested(delta, in: &rows[workspaceIndex].value, entity: entity)
        if changed { removedMetadata[rows[workspaceIndex].key] = metadata[rows[workspaceIndex].key] }
        refreshMetadata(for: rows[workspaceIndex].key, at: workspaceIndex)
        if !changed && (delta.kind.isAdd || delta.kind.isClose) { return ([], false) }
        // Renames keep structure intact. Changed entities may replace children
        // or change tab kind, so retain the full consumer reconciliation there.
        return (Set([id]), delta.kind != .tabRenamed && delta.kind != .screenRenamed)
    }

    private func patchWorkspace(_ delta: DaemonTreeDelta) throws -> (ids: Set<String>, topology: Bool) {
        if delta.kind == .workspaceAdded {
            if rowIndex(workspace: delta.workspace, key: delta.workspaceKey) != nil {
                // A subscribe-before-snapshot replay may contain the add that
                // is already represented by the snapshot. It is a no-op.
                return ([], false)
            }
            guard let entity = delta.entity.flatMap(Self.object) else { throw ProjectionError.needsSnapshot }
            let row = Row(value: entity, key: Self.rowKey(entity), handle: entity["id"] as? Int)
            let index = min(max(delta.index ?? rows.count, 0), rows.count)
            rows.insert(row, at: index)
            metadata[row.key] = Self.metadata(for: row.value)
            // Insertion shifts every later row's surface index.
            rebuildSurfaceIndex()
            return (Set([row.key]), true)
        }
        guard let index = rowIndex(workspace: delta.workspace, key: delta.workspaceKey) else {
            if delta.kind.isClose { return ([], false) }
            throw ProjectionError.needsSnapshot
        }
        let oldID = try rowID(at: index)
        if delta.kind == .workspaceClosed {
            removedMetadata[oldID] = metadata.removeValue(forKey: oldID)
            rows.remove(at: index)
            rebuildSurfaceIndex()
            return (Set([oldID]), true)
        }
        guard let entity = delta.entity.flatMap(Self.object) else { throw ProjectionError.needsSnapshot }
        let row = Row(value: entity, key: Self.rowKey(entity), handle: entity["id"] as? Int)
        rows[index] = row
        removedMetadata[oldID] = metadata[oldID]
        if row.key != oldID { metadata.removeValue(forKey: oldID) }
        refreshMetadata(for: row.key, at: index)
        if row.key != oldID { rebuildSurfaceIndex() }
        if delta.kind == .workspaceMoved, let target = delta.index {
            let moved = rows.remove(at: index)
            rows.insert(moved, at: min(max(target, 0), rows.count))
            rebuildSurfaceIndex()
        }
        return (Set([oldID, row.key]), true)
    }

    /// Patches a screen, pane, or tab in-place. Returns whether row topology
    /// changed (add/close); metadata/rename deltas preserve the row identity.
    private func patchNested(_ delta: DaemonTreeDelta, in workspace: inout [String: Any], entity: [String: Any]?) throws -> Bool {
        guard var screens = workspace["screens"] as? [[String: Any] ] else { throw ProjectionError.needsSnapshot }
        guard let screenID = delta.screen else { throw ProjectionError.needsSnapshot }
        if delta.kind.rawValue.hasPrefix("screen-") {
            if delta.kind.isAdd {
                guard let entity else { throw ProjectionError.needsSnapshot }
                if screens.contains(where: { ($0["id"] as? Int) == screenID }) { return false }
                screens.insert(entity, at: min(max(delta.index ?? screens.count, 0), screens.count))
                workspace["screens"] = screens
                return true
            }
            guard let screenIndex = screens.firstIndex(where: { ($0["id"] as? Int) == screenID }) else {
                if delta.kind.isClose { return false }
                throw ProjectionError.needsSnapshot
            }
            if delta.kind.isClose { screens.remove(at: screenIndex) }
            else {
                guard let entity else { throw ProjectionError.needsSnapshot }
                screens[screenIndex] = entity
            }
            workspace["screens"] = screens
            return true
        }
        guard let screenIndex = screens.firstIndex(where: { ($0["id"] as? Int) == screenID }) else {
            if delta.kind.isClose { return false }
            throw ProjectionError.needsSnapshot
        }
        guard var panes = screens[screenIndex]["panes"] as? [[String: Any]], let paneID = delta.pane else { throw ProjectionError.needsSnapshot }
        if delta.kind.rawValue.hasPrefix("pane-") {
            if delta.kind.isAdd {
                guard let entity else { throw ProjectionError.needsSnapshot }
                if panes.contains(where: { ($0["id"] as? Int) == paneID }) { return false }
                panes.insert(entity, at: min(max(delta.index ?? panes.count, 0), panes.count))
                screens[screenIndex]["panes"] = panes
                workspace["screens"] = screens
                return true
            }
            guard let paneIndex = panes.firstIndex(where: { ($0["id"] as? Int) == paneID }) else {
                if delta.kind.isClose { return false }
                throw ProjectionError.needsSnapshot
            }
            if delta.kind.isClose { panes.remove(at: paneIndex) }
            else {
                guard let entity else { throw ProjectionError.needsSnapshot }
                panes[paneIndex] = entity
            }
            screens[screenIndex]["panes"] = panes
            workspace["screens"] = screens
            return true
        }
        guard let paneIndex = panes.firstIndex(where: { ($0["id"] as? Int) == paneID }),
              var tabs = panes[paneIndex]["tabs"] as? [[String: Any]], let surface = delta.surface else {
            if delta.kind.isClose { return false }
            throw ProjectionError.needsSnapshot
        }
        let selectedIndex = panes[paneIndex]["active_tab"] as? Int
        let selected = selectedIndex.flatMap {
            tabs.indices.contains($0) ? tabs[$0]["surface"] as? Int : nil
        }
        if delta.kind.isAdd {
            guard let entity else { throw ProjectionError.needsSnapshot }
            if tabs.contains(where: { ($0["surface"] as? Int) == surface }) { return false }
            tabs.insert(entity, at: min(max(delta.index ?? tabs.count, 0), tabs.count))
        } else {
            guard let tabIndex = tabs.firstIndex(where: { ($0["surface"] as? Int) == surface }) else {
                if delta.kind.isClose { return false }
                throw ProjectionError.needsSnapshot
            }
            if delta.kind.isClose { tabs.remove(at: tabIndex) }
            else {
                guard let entity else { throw ProjectionError.needsSnapshot }
                tabs[tabIndex] = entity
                if let destination = delta.index, destination != tabIndex {
                    let moved = tabs.remove(at: tabIndex)
                    tabs.insert(moved, at: min(max(destination, 0), tabs.count))
                }
            }
        }
        // Selection is a surface identity; active_tab is only its current
        // position. Preserve it through every membership/order mutation.
        if let selected, let index = tabs.firstIndex(where: { $0["surface"] as? Int == selected }) {
            panes[paneIndex]["active_tab"] = index
        } else if delta.kind.isClose, selected == surface, let selectedIndex {
            // Match the daemon's close policy: preceding tab, or the first
            // survivor when closing index zero. Empty panes have no selection.
            if tabs.isEmpty { panes[paneIndex].removeValue(forKey: "active_tab") }
            else { panes[paneIndex]["active_tab"] = min(max(selectedIndex - 1, 0), tabs.count - 1) }
        }
        panes[paneIndex]["tabs"] = tabs
        screens[screenIndex]["panes"] = panes
        workspace["screens"] = screens
        return delta.kind.isAdd || delta.kind.isClose
    }

    // MARK: Projection and row parsing

    private func publish(changed IDs: Set<String>, topology: Bool) throws -> Update? {
        guard var current = tree, !IDs.isEmpty else { return nil }
        var changed = Set<String>()
        for id in IDs {
            guard let index = rows.firstIndex(where: { $0.key == id }) else {
                // A closed row is removed from the current tree below.
                continue
            }
            let parsed = try parseRow(rows[index], previous: Self.workspace(id: id, in: current))
            replace(parsed, id: id, in: &current)
            refreshMetadata(for: id, at: index)
            changed.insert(id)
        }
        // Closed workspaces no longer have a raw row; remove them from the
        // value tree and all index maps.
        let live = Set(rows.map(\.key))
        for old in current.workspaces + current.homeWorkspaces where !live.contains(old.id) {
            remove(old, from: &current)
            changed.insert(old.id)
        }
        if topology {
            reorder(&current)
            current.apply(arrangement)
        }
        current.revision = revision
        current.registryID = registryID
        tree = current
        return Update(tree: current, changedWorkspaceIDs: changed, topology: topology)
    }

    private func parseRow(_ row: Row, previous: Workspace?) throws -> DaemonTree {
        var data: [String: Any] = ["workspaces": [row.value]]
        if let revision { data["workspace_revision"] = revision }
        if let registryID { data["registry_id"] = registryID }
        let envelope: [String: Any] = ["ok": true, "data": data]
        let bytes = try JSONSerialization.data(withJSONObject: envelope)
        return try DaemonTree(reply: bytes, macID: macID, previous: previous.map { [$0] } ?? [], agents: agents, activity: activity)
    }

    private func replace(_ parsed: DaemonTree, id: String, in current: inout DaemonTree) {
        let old = Self.workspace(id: id, in: current)
        let oldHomeIndex = old.flatMap { current.homeWorkspaces.firstIndex(of: $0) }
        let oldIndex = old.flatMap { current.workspaces.firstIndex(of: $0) }
        if let old { remove(old, from: &current) }
        guard var replacement = parsed.workspaces.first ?? parsed.homeWorkspaces.first else { return }
        if let old {
            replacement.isPinned = old.isPinned
            replacement.pinIndex = old.pinIndex
            replacement.pinItemID = old.pinItemID
            replacement.sidebarIndex = old.sidebarIndex
            replacement.group = old.group
        }
        if replacement.isHome {
            let index = min(oldHomeIndex ?? current.homeWorkspaces.count, current.homeWorkspaces.count)
            current.homeWorkspaces.insert(replacement, at: index)
        } else {
            let index = min(oldIndex ?? current.workspaces.count, current.workspaces.count)
            current.workspaces.insert(replacement, at: index)
        }
        current.agentTabs.merge(parsed.agentTabs) { _, new in new }
        current.surfaces.merge(parsed.surfaces) { _, new in new }
        current.directories.merge(parsed.directories) { _, new in new }
        current.panes.merge(parsed.panes) { _, new in new }
        current.tabPlaces.merge(parsed.tabPlaces) { _, new in new }
        current.terminals.merge(parsed.terminals) { _, new in new }
        current.workspaceNumbers.merge(parsed.workspaceNumbers) { _, new in new }
        current.groupPanes.merge(parsed.groupPanes) { _, new in new }
        current.notificationMarkers.merge(parsed.notificationMarkers) { _, new in new }
        current.legacyPinned.formUnion(parsed.legacyPinned)
    }

    private func remove(_ workspace: Workspace, from tree: inout DaemonTree) {
        tree.workspaces.removeAll { $0.id == workspace.id }
        tree.homeWorkspaces.removeAll { $0.id == workspace.id }
        // A changed row has already refreshed `metadata`; consume the
        // previous membership captured by apply so removed tabs and groups
        // are purged from the derived dictionaries.
        let rowMetadata = removedMetadata.removeValue(forKey: workspace.id) ?? metadata[workspace.id]
        let tabs = rowMetadata?.tabs ?? Set(workspace.tabs.map(\.id))
        let tabSurfaces = rowMetadata?.surfaces ?? Set(workspace.tabs.compactMap { tree.surfaces[$0.id] })
        for tab in tabs {
            tree.agentTabs.removeValue(forKey: tab)
            tree.surfaces.removeValue(forKey: tab)
            tree.directories.removeValue(forKey: tab)
            tree.tabPlaces.removeValue(forKey: tab)
            if let terminal = tree.terminals.removeValue(forKey: tab) { _ = terminal }
        }
        for surface in tabSurfaces { tree.notificationMarkers.removeValue(forKey: surface) }
        for group in rowMetadata?.groups ?? [] { tree.groupPanes.removeValue(forKey: group) }
        tree.panes.removeValue(forKey: workspace.id)
        tree.workspaceNumbers.removeValue(forKey: workspace.id)
        tree.legacyPinned.remove(workspace.id)
    }

    private func reorder(_ tree: inout DaemonTree) {
        let byID = Dictionary((tree.workspaces + tree.homeWorkspaces).map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        tree.workspaces = rows.filter { !$0.isHome }.compactMap { byID[$0.key] }
        tree.homeWorkspaces = rows.filter(\.isHome).compactMap { byID[$0.key] }
    }

    // MARK: Raw lookup helpers

    private func rowIndex(workspace: Int?, key: String?) -> Int? {
        rows.firstIndex { row in
            (key != nil && row.key == key) || (workspace != nil && row.handle == workspace)
        }
    }

    private func rowIndex(surface: Int) -> Int? {
        surfaceRows[surface]
    }

    private func rowID(at index: Int) throws -> String {
        guard rows.indices.contains(index) else { throw ProjectionError.needsSnapshot }
        return rows[index].key
    }

    private static func rowKey(_ row: [String: Any]) -> String {
        (row["key"] as? String) ?? (row["id"] as? Int).map { "w\($0)" } ?? ""
    }

    private static func object(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func tabs(_ row: [String: Any]) -> [[String: Any]] {
        (row["screens"] as? [[String: Any]] ?? []).flatMap { screen in
            (screen["panes"] as? [[String: Any]] ?? []).flatMap { $0["tabs"] as? [[String: Any]] ?? [] }
        }
    }

    private static func metadata(for row: [String: Any]) -> RowMetadata {
        var tabs = Set<String>(), surfaces = Set<Int>(), groups = Set<String>()
        for tab in Self.tabs(row) {
            guard let surface = tab["surface"] as? Int else { continue }
            surfaces.insert(surface)
            tabs.insert(DaemonTree.tabID(surface: surface))
        }
        for screen in row["screens"] as? [[String: Any]] ?? [] {
            for pane in screen["panes"] as? [[String: Any]] ?? [] {
                for group in pane["tab_groups"] as? [[String: Any]] ?? [] {
                    if let id = group["id"] as? String { groups.insert(id) }
                }
            }
        }
        return RowMetadata(tabs: tabs, surfaces: surfaces, groups: groups)
    }

    private func rebuildSurfaceIndex() {
        surfaceRows = [:]
        for (index, row) in rows.enumerated() {
            for surface in Self.metadata(for: row.value).surfaces { surfaceRows[surface] = index }
        }
    }

    private func refreshMetadata(for id: String, at index: Int) {
        let old = metadata[id]
        let next = Self.metadata(for: rows[index].value)
        metadata[id] = next
        for surface in old?.surfaces ?? [] where next.surfaces.contains(surface) == false {
            surfaceRows.removeValue(forKey: surface)
        }
        for surface in next.surfaces { surfaceRows[surface] = index }
    }

    private static func agentSession(_ tab: [String: Any]) -> String? {
        ((tab["conversation"] as? [String: Any])?["agent_session"] as? [String: Any])?["session"] as? String
    }

    private static func workspace(id: String, in tree: DaemonTree) -> Workspace? {
        (tree.workspaces + tree.homeWorkspaces).first { $0.id == id }
    }
}

fileprivate extension WorkspaceProjection.Row {
    mutating func setTitle(surface: Int, title: String) {
        guard var screens = value["screens"] as? [[String: Any]] else { return }
        for screenIndex in screens.indices {
            guard var panes = screens[screenIndex]["panes"] as? [[String: Any]] else { continue }
            for paneIndex in panes.indices {
                guard var tabs = panes[paneIndex]["tabs"] as? [[String: Any]] else { continue }
                guard let tabIndex = tabs.firstIndex(where: { ($0["surface"] as? Int) == surface }) else { continue }
                tabs[tabIndex]["title"] = title
                panes[paneIndex]["tabs"] = tabs
                screens[screenIndex]["panes"] = panes
                value["screens"] = screens
                return
            }
        }
    }
}
