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
        /// Each agent tab's acpmux session, by surface (`conversation.agent_session`).
        var sessions: [Int: String]
    }

    /// Where a workspace sits in the published tree.
    private struct TreeSlot {
        var home: Bool
        var index: Int
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
    /// Row positions by key and by daemon handle (the first row with it), so a
    /// delta finds its row without reading the list.
    private var keyRows: [String: Int] = [:]
    private var handleRows: [Int: Int] = [:]
    /// Each acpmux session's surfaces, with how many rows list each one: an
    /// ask's change finds its tabs without reading every row.
    private var sessionSurfaces: [String: [Int: Int]] = [:]
    /// Each workspace's place in `tree`, rebuilt when its order changes.
    private var treeSlots: [String: TreeSlot] = [:]
    /// The rows' order or membership changed since the tree was last ordered.
    private var rowsReordered = false
    /// Rows read by whole-list passes (list scans, index rebuilds, reorders,
    /// the arrangement) since this projection was made: the work a delta adds
    /// beyond its own row. `WorkspaceProjectionCostTests` holds a one-row
    /// delta's share of it the same at 1,000 workspaces as at 200.
    private(set) var scannedRows = 0

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
        metadata = [:]
        sessionSurfaces = [:]
        for row in rows { setMetadata(Self.metadata(for: row.value), for: row.key) }
        removedMetadata = [:]
        rebuildRowIndexes()
        rowsReordered = false
        rebuildTreeSlots(parsed)
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
        if old.pending != agents.pending || old.waitingFor != agents.waitingFor || old.chatTitles != agents.chatTitles {
            var sessions = Set(old.pending.keys).union(agents.pending.keys).union(old.waitingFor.keys).union(agents.waitingFor.keys)
            for session in Set(old.chatTitles.keys).union(agents.chatTitles.keys)
                where old.chatTitles[session] != agents.chatTitles[session] { sessions.insert(session) }
            for session in sessions {
                if let listed = sessionSurfaces[session] { surfaces.formUnion(listed.keys) }
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
            setMetadata(Self.metadata(for: row.value), for: row.key)
            // Insertion shifts every later row's index.
            rebuildRowIndexes()
            return (Set([row.key]), true)
        }
        guard let index = rowIndex(workspace: delta.workspace, key: delta.workspaceKey) else {
            if delta.kind.isClose { return ([], false) }
            throw ProjectionError.needsSnapshot
        }
        let oldID = try rowID(at: index)
        if delta.kind == .workspaceClosed {
            removedMetadata[oldID] = setMetadata(nil, for: oldID)
            rows.remove(at: index)
            rebuildRowIndexes()
            return (Set([oldID]), true)
        }
        guard let entity = delta.entity.flatMap(Self.object) else { throw ProjectionError.needsSnapshot }
        let row = Row(value: entity, key: Self.rowKey(entity), handle: entity["id"] as? Int)
        let oldHandle = rows[index].handle
        rows[index] = row
        removedMetadata[oldID] = metadata[oldID]
        if row.key != oldID { setMetadata(nil, for: oldID) }
        refreshMetadata(for: row.key, at: index)
        if delta.kind == .workspaceMoved, let target = delta.index {
            let moved = rows.remove(at: index)
            rows.insert(moved, at: min(max(target, 0), rows.count))
            rebuildRowIndexes()
        } else if row.key != oldID || row.handle != oldHandle {
            rebuildRowIndexes()
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

    /// Publishes the rows in `IDs`. A one-row change costs one row at any
    /// workspace count: rows and tree slots come from the indexes, the row is
    /// replaced in place, and the derived maps change only where the row's
    /// entries differ (so their storage, shared with the last published tree,
    /// is not copied). The whole list is read again only when its order,
    /// membership or arrangement inputs changed.
    private func publish(changed IDs: Set<String>, topology: Bool) throws -> Update? {
        guard var current = tree, !IDs.isEmpty else { return nil }
        var changed = Set<String>()
        // The tree's membership or order changed, so its slots are stale.
        var reshaped = false
        // A replaced row's pin or arrangement inputs changed.
        var rearranged = false
        for id in IDs {
            guard let index = rowIndex(key: id) else {
                // A closed row is removed from the current tree below.
                continue
            }
            let slot = slot(of: id, in: current)
            let old = slot.map { Self.workspace(at: $0, in: current) }
            let parsed = try parseRow(rows[index], previous: old)
            switch replace(parsed, id: id, old: old, slot: slot, in: &current) {
            case .inPlace(let sameArrangement): if !sameArrangement { rearranged = true }
            case .moved:
                reshaped = true
                rebuildTreeSlots(current)
            }
            refreshMetadata(for: id, at: index)
            changed.insert(id)
        }
        // Closed workspaces no longer have a raw row; remove them from the
        // value tree and all index maps. Only a changed id can have closed:
        // every other tree workspace still has its row.
        for id in IDs where rowIndex(key: id) == nil {
            guard let slot = slot(of: id, in: current) else { continue }
            remove(Self.workspace(at: slot, in: current), from: &current)
            changed.insert(id)
            reshaped = true
            rebuildTreeSlots(current)
        }
        if topology, reshaped || rearranged || rowsReordered {
            reorder(&current)
            current.apply(arrangement)
            scannedRows += current.workspaces.count
            rowsReordered = false
            rebuildTreeSlots(current)
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

    private enum Replacement {
        /// Replaced at its own place; `sameArrangement` when its resource id
        /// and legacy pin are what they were, so pins and places still hold.
        case inPlace(sameArrangement: Bool)
        /// Added, removed, or moved between the home and listed workspaces.
        case moved
    }

    private func replace(_ parsed: DaemonTree, id: String, old: Workspace?, slot: TreeSlot?,
                         in current: inout DaemonTree) -> Replacement {
        guard var replacement = parsed.workspaces.first ?? parsed.homeWorkspaces.first else {
            if let old { remove(old, from: &current) }
            return .moved
        }
        guard let old, let slot, replacement.isHome == slot.home else {
            // New, or between home and the list: remove and insert, as a
            // whole-list change.
            let oldHomeIndex = old.flatMap { old in current.homeWorkspaces.firstIndex { $0.id == old.id } }
            let oldIndex = old.flatMap { old in current.workspaces.firstIndex { $0.id == old.id } }
            scannedRows += current.workspaces.count + current.homeWorkspaces.count
            if let old {
                remove(old, from: &current)
                Self.keepArrangement(of: old, in: &replacement)
            }
            if replacement.isHome {
                current.homeWorkspaces.insert(replacement, at: min(oldHomeIndex ?? current.homeWorkspaces.count, current.homeWorkspaces.count))
            } else {
                current.workspaces.insert(replacement, at: min(oldIndex ?? current.workspaces.count, current.workspaces.count))
            }
            Self.merge(parsed, into: &current)
            return .moved
        }
        Self.keepArrangement(of: old, in: &replacement)
        if slot.home {
            if current.homeWorkspaces[slot.index] != replacement { current.homeWorkspaces[slot.index] = replacement }
        } else if current.workspaces[slot.index] != replacement {
            current.workspaces[slot.index] = replacement
        }
        // The same entries `remove` then `merge` leave, written only where
        // they differ.
        let rowMetadata = removedMetadata.removeValue(forKey: id) ?? metadata[id]
        let tabs = rowMetadata?.tabs ?? Set(old.tabs.map(\.id))
        let tabSurfaces = rowMetadata?.surfaces ?? Set(old.tabs.compactMap { current.surfaces[$0.id] })
        Self.replaceEntries(&current.agentTabs, keys: tabs, with: parsed.agentTabs)
        Self.replaceEntries(&current.surfaces, keys: tabs, with: parsed.surfaces)
        Self.replaceEntries(&current.directories, keys: tabs, with: parsed.directories)
        Self.replaceEntries(&current.tabPlaces, keys: tabs, with: parsed.tabPlaces)
        Self.replaceEntries(&current.terminals, keys: tabs, with: parsed.terminals)
        Self.replaceEntries(&current.notificationMarkers, keys: tabSurfaces, with: parsed.notificationMarkers)
        Self.replaceEntries(&current.groupPanes, keys: rowMetadata?.groups ?? [], with: parsed.groupPanes)
        Self.replaceEntries(&current.panes, keys: [id], with: parsed.panes)
        Self.replaceEntries(&current.workspaceNumbers, keys: [id], with: parsed.workspaceNumbers)
        let wasPinned = current.legacyPinned.contains(id)
        if wasPinned, !parsed.legacyPinned.contains(id) { current.legacyPinned.remove(id) }
        for pinned in parsed.legacyPinned where !current.legacyPinned.contains(pinned) { current.legacyPinned.insert(pinned) }
        return .inPlace(sameArrangement: old.resourceID == replacement.resourceID && wasPinned == current.legacyPinned.contains(id))
    }

    private static func keepArrangement(of old: Workspace, in replacement: inout Workspace) {
        replacement.isPinned = old.isPinned
        replacement.pinIndex = old.pinIndex
        replacement.pinItemID = old.pinItemID
        replacement.sidebarIndex = old.sidebarIndex
        replacement.group = old.group
    }

    private static func merge(_ parsed: DaemonTree, into current: inout DaemonTree) {
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

    /// `dict` without `keys`, then with `new`: what removing a row's entries
    /// and merging its new ones gives, writing only the entries that change.
    private static func replaceEntries<Key: Hashable, Value: Equatable>(_ dict: inout [Key: Value], keys: Set<Key>, with new: [Key: Value]) {
        for key in keys where new[key] == nil && dict[key] != nil { dict.removeValue(forKey: key) }
        for (key, value) in new where dict[key] != value { dict[key] = value }
    }

    private func remove(_ workspace: Workspace, from tree: inout DaemonTree) {
        scannedRows += tree.workspaces.count + tree.homeWorkspaces.count
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
        scannedRows += rows.count + tree.workspaces.count + tree.homeWorkspaces.count
        let byID = Dictionary((tree.workspaces + tree.homeWorkspaces).map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        tree.workspaces = rows.filter { !$0.isHome }.compactMap { byID[$0.key] }
        tree.homeWorkspaces = rows.filter(\.isHome).compactMap { byID[$0.key] }
    }

    // MARK: Raw lookup helpers

    /// The first row with `key` or `workspace` as its handle, as a scan of
    /// the rows finds it.
    private func rowIndex(workspace: Int?, key: String?) -> Int? {
        let byKey = key.flatMap { keyRows[$0] }
        let byHandle = workspace.flatMap { handleRows[$0] }
        // The indexes are rebuilt with every insert, remove, move and re-key;
        // one that disagrees with the rows falls back to reading them.
        let stale = byKey.map { !rows.indices.contains($0) || rows[$0].key != key } == true
            || byHandle.map { !rows.indices.contains($0) || rows[$0].handle != workspace } == true
        if stale {
            scannedRows += rows.count
            return rows.firstIndex { row in
                (key != nil && row.key == key) || (workspace != nil && row.handle == workspace)
            }
        }
        if let byKey, let byHandle { return min(byKey, byHandle) }
        return byKey ?? byHandle
    }

    private func rowIndex(key: String) -> Int? {
        rowIndex(workspace: nil, key: key)
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
        var tabs = Set<String>(), surfaces = Set<Int>(), groups = Set<String>(), sessions: [Int: String] = [:]
        for tab in Self.tabs(row) {
            guard let surface = tab["surface"] as? Int else { continue }
            surfaces.insert(surface)
            tabs.insert(DaemonTree.tabID(surface: surface))
            if let session = Self.agentSession(tab) { sessions[surface] = session }
        }
        for screen in row["screens"] as? [[String: Any]] ?? [] {
            for pane in screen["panes"] as? [[String: Any]] ?? [] {
                for group in pane["tab_groups"] as? [[String: Any]] ?? [] {
                    if let id = group["id"] as? String { groups.insert(id) }
                }
            }
        }
        return RowMetadata(tabs: tabs, surfaces: surfaces, groups: groups, sessions: sessions)
    }

    /// Rebuilds the key, handle and surface indexes after rows were inserted,
    /// removed, moved or re-keyed, from the cached row metadata.
    private func rebuildRowIndexes() {
        scannedRows += rows.count
        keyRows = [:]
        handleRows = [:]
        surfaceRows = [:]
        for (index, row) in rows.enumerated() {
            if keyRows[row.key] == nil { keyRows[row.key] = index }
            if let handle = row.handle, handleRows[handle] == nil { handleRows[handle] = index }
            for surface in metadata[row.key]?.surfaces ?? [] { surfaceRows[surface] = index }
        }
        rowsReordered = true
    }

    private func rebuildTreeSlots(_ tree: DaemonTree) {
        scannedRows += tree.workspaces.count + tree.homeWorkspaces.count
        treeSlots = [:]
        for (index, workspace) in tree.workspaces.enumerated() where treeSlots[workspace.id] == nil {
            treeSlots[workspace.id] = TreeSlot(home: false, index: index)
        }
        for (index, workspace) in tree.homeWorkspaces.enumerated() where treeSlots[workspace.id] == nil {
            treeSlots[workspace.id] = TreeSlot(home: true, index: index)
        }
    }

    /// The workspace's place in `tree`: the listed workspaces first, then
    /// home, as a scan of both finds it.
    private func slot(of id: String, in tree: DaemonTree) -> TreeSlot? {
        if let slot = treeSlots[id] {
            let count = slot.home ? tree.homeWorkspaces.count : tree.workspaces.count
            if slot.index < count, Self.workspace(at: slot, in: tree).id == id { return slot }
        }
        // Not indexed (a new row) or stale: read the lists.
        scannedRows += tree.workspaces.count + tree.homeWorkspaces.count
        if let index = tree.workspaces.firstIndex(where: { $0.id == id }) { return TreeSlot(home: false, index: index) }
        return tree.homeWorkspaces.firstIndex { $0.id == id }.map { TreeSlot(home: true, index: $0) }
    }

    private static func workspace(at slot: TreeSlot, in tree: DaemonTree) -> Workspace {
        slot.home ? tree.homeWorkspaces[slot.index] : tree.workspaces[slot.index]
    }

    private func refreshMetadata(for id: String, at index: Int) {
        let old = setMetadata(Self.metadata(for: rows[index].value), for: id)
        let next = metadata[id]
        for surface in old?.surfaces ?? [] where next?.surfaces.contains(surface) == false {
            surfaceRows.removeValue(forKey: surface)
        }
        for surface in next?.surfaces ?? [] { surfaceRows[surface] = index }
    }

    /// Sets (or with nil removes) a row's metadata and keeps the session
    /// index in step. Returns the metadata it replaced.
    @discardableResult
    private func setMetadata(_ next: RowMetadata?, for id: String) -> RowMetadata? {
        let old: RowMetadata?
        if let next { old = metadata.updateValue(next, forKey: id) } else { old = metadata.removeValue(forKey: id) }
        for (surface, session) in old?.sessions ?? [:] where next?.sessions[surface] != session {
            let count = (sessionSurfaces[session]?[surface] ?? 1) - 1
            sessionSurfaces[session]?[surface] = count > 0 ? count : nil
            if sessionSurfaces[session]?.isEmpty == true { sessionSurfaces.removeValue(forKey: session) }
        }
        for (surface, session) in next?.sessions ?? [:] where old?.sessions[surface] != session {
            sessionSurfaces[session, default: [:]][surface, default: 0] += 1
        }
        return old
    }

    private static func agentSession(_ tab: [String: Any]) -> String? {
        ((tab["conversation"] as? [String: Any])?["agent_session"] as? [String: Any])?["session"] as? String
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
