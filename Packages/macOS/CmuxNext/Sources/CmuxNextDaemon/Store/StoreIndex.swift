import Foundation

/// The store's O(1) lookups (perf-speed-of-light.md I2, I3), kept in step
/// with the records by each change instead of a rebuild of the whole tree.
///
/// Every record is indexed under the keys it had when it was indexed, and
/// knows its parent and children here. `insert` (re)indexes one record and
/// its subtree: it first drops what the record was indexed under, so a
/// record whose ids, children or parent changed (an `update`, a move) is
/// indexed again exactly. `remove` drops a record and its subtree. A key
/// is dropped only while it still names the same record, so two records
/// that pass one key between them in one batch stay correct. The cost of
/// each call is the size of the subtree it names, never the whole tree.
///
/// Rule for writers: every change of a record's ids or children (an
/// `update` from a snapshot, an insert, a removal, a move) is followed by
/// `insert` of the changed record (or `remove`), in the same turn.
@MainActor struct StoreIndex {
    private(set) var tabsBySurface: [SurfaceID: TabModel] = [:]
    private(set) var tabsByID: [String: TabModel] = [:]
    private(set) var tabsByTerminal: [TerminalID: TabModel] = [:]
    private(set) var tabsByResource: [ResourceID: TabModel] = [:]
    private(set) var tabsByTerminalResource: [ResourceID: TabModel] = [:]
    private(set) var panesByHandle: [PaneID: PaneModel] = [:]
    private(set) var panesByResource: [ResourceID: PaneModel] = [:]
    /// Indexed pane records per durable id (``PaneModel/id``): a watcher asks about its own panes.
    /// A count, not one record: while a pane moves between workspaces its added delta indexes a
    /// second record of the same id before the source's closed delta drops the first.
    private var paneRecordsByID: [String: Int] = [:]

    /// Whether any indexed pane record has durable id `id`.
    func listsPane(id: String) -> Bool { paneRecordsByID[id] != nil }
    private(set) var screensByHandle: [ScreenID: ScreenModel] = [:]
    private(set) var screensByResource: [ResourceID: ScreenModel] = [:]
    private(set) var workspacesByHandle: [WorkspaceHandle: WorkspaceModel] = [:]
    private(set) var workspacesByKey: [WorkspaceKey: WorkspaceModel] = [:]
    private(set) var workspacesByID: [String: WorkspaceModel] = [:]
    private(set) var workspacesByResource: [ResourceID: WorkspaceModel] = [:]
    private(set) var tabGroupsByID: [TabGroupID: TabGroupModel] = [:]
    /// Indexed tabs the intent overlay shows (``isOverlayTab(id:surface:)``).
    private(set) var provisionalTabCount = 0
    /// An order-free digest of which tab sits in which pane, and which panes there are (XOR of one
    /// hash per indexed tab and its pane, and one per pane): a remove and re-add of the same tab in
    /// the same pane leaves it as it was, so a refresh changes it only when a tab came, went or
    /// moved to another pane, or a pane came or went (with tabs or not).
    private var tabMembership = 0
    private var takenMembership = 0
    /// An order change inside a pane, or of the workspaces, noted by its
    /// writer (`noteTabOrderChanged`).
    private var tabOrderChanged = false

    private enum Keys {
        case workspace(handle: WorkspaceHandle, key: WorkspaceKey?, id: String, resource: ResourceID?)
        case screen(handle: ScreenID, resource: ResourceID?)
        case pane(handle: PaneID, resource: ResourceID?, groups: [TabGroupModel])
        case tab(surface: SurfaceID, id: String, terminal: TerminalID?, resource: ResourceID?, terminalResource: ResourceID?)
    }

    private struct Entry {
        let record: AnyObject
        var keys: Keys
        var parent: ObjectIdentifier?
        var children: Set<ObjectIdentifier> = []
        /// A tab's or a pane's share of `tabMembership` (0 for other records).
        var membership = 0
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    /// Records indexed since creation (each ``insert`` counts its subtree): what a store change
    /// cost here. Tests and `debug.store` read it; a snapshot that changed one workspace must add
    /// that workspace's records, not the session's.
    private(set) var indexedRecords = 0
    /// Every indexed tab record per surface: normally one; two for the
    /// moment a move's added delta carries its own record of the moved tab.
    private var recordsBySurface: [SurfaceID: [ObjectIdentifier]] = [:]

    /// The indexed tab records on `surface` (normally one).
    func tabs(onSurface surface: SurfaceID) -> [TabModel] {
        (recordsBySurface[surface] ?? []).compactMap { entries[$0]?.record as? TabModel }
    }

    // MARK: Parents

    func pane(holding tab: TabModel) -> PaneModel? {
        entries[ObjectIdentifier(tab)]?.parent.flatMap { entries[$0]?.record as? PaneModel }
    }

    func screen(holding pane: PaneModel) -> ScreenModel? {
        entries[ObjectIdentifier(pane)]?.parent.flatMap { entries[$0]?.record as? ScreenModel }
    }

    func workspace(holding screen: ScreenModel) -> WorkspaceModel? {
        entries[ObjectIdentifier(screen)]?.parent.flatMap { entries[$0]?.record as? WorkspaceModel }
    }

    // MARK: Writes

    /// Indexes `workspaces` only (snapshot apply; the one O(tree) write).
    mutating func rebuild(_ workspaces: [WorkspaceModel]) {
        let counted = indexedRecords
        self = StoreIndex()
        indexedRecords = counted
        for workspace in workspaces { insert(workspace) }
        tabOrderChanged = true
    }

    /// The order of tabs in a pane, or of the workspaces, changed.
    mutating func noteTabOrderChanged() { tabOrderChanged = true }

    /// Whether the tab list (tabs, their panes, their order) changed since
    /// the last call; resets it.
    mutating func takeTabListChange() -> Bool {
        defer { (takenMembership, tabOrderChanged) = (tabMembership, false) }
        return tabOrderChanged || tabMembership != takenMembership
    }

    /// By the pane's handle, not its record: an overlay that makes the same
    /// provisional pane again on every restore changes nothing.
    private static func membership(_ tab: TabModel, _ pane: PaneID?) -> Int {
        var hasher = Hasher()
        hasher.combine(tab.id)
        hasher.combine(tab.resourceID)
        hasher.combine(tab.terminalID)
        hasher.combine(tab.terminalResourceID)
        hasher.combine(pane)
        return hasher.finalize()
    }

    private static func membership(_ pane: PaneModel) -> Int {
        var hasher = Hasher()
        hasher.combine("pane")
        hasher.combine(pane.id)
        // The handle too: two records of one id (a pane moving between workspaces) must not cancel
        // in the XOR when both go in one publish.
        hasher.combine(pane.handle)
        return hasher.finalize()
    }

    mutating func insert(_ workspace: WorkspaceModel) {
        remove(workspace)
        add(workspace, .workspace(handle: workspace.handle, key: workspace.key, id: workspace.id, resource: workspace.resourceID), parent: nil)
        for screen in workspace.screens { insert(screen, in: workspace) }
    }

    mutating func insert(_ screen: ScreenModel, in workspace: WorkspaceModel) {
        remove(screen)
        add(screen, .screen(handle: screen.handle, resource: screen.resourceID), parent: workspace)
        for pane in screen.panes { insert(pane, in: screen) }
    }

    mutating func insert(_ pane: PaneModel, in screen: ScreenModel) {
        remove(pane)
        add(pane, .pane(handle: pane.handle, resource: pane.resourceID, groups: pane.tabGroups), parent: screen)
        for tab in pane.tabs { insert(tab, in: pane) }
    }

    mutating func insert(_ tab: TabModel, in pane: PaneModel) {
        remove(tab)
        add(tab, .tab(surface: tab.surface, id: tab.id, terminal: tab.terminalID, resource: tab.resourceID,
                      terminalResource: tab.terminalResourceID), parent: pane)
    }

    /// Drops `record` (a workspace, screen, pane or tab) and its subtree.
    mutating func remove(_ record: AnyObject) {
        remove(id: ObjectIdentifier(record))
    }

    private mutating func remove(id: ObjectIdentifier) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        tabMembership ^= entry.membership
        for child in entry.children { remove(id: child) }
        if let parent = entry.parent { entries[parent]?.children.remove(id) }
        unkey(entry.keys, entry.record)
    }

    private mutating func add(_ record: AnyObject, _ keys: Keys, parent: AnyObject?) {
        let id = ObjectIdentifier(record)
        let parentID = parent.map(ObjectIdentifier.init)
        var entry = Entry(record: record, keys: keys, parent: parentID)
        if let tab = record as? TabModel {
            entry.membership = Self.membership(tab, (parent as? PaneModel)?.handle)
            tabMembership ^= entry.membership
        } else if let pane = record as? PaneModel {
            entry.membership = Self.membership(pane)
            tabMembership ^= entry.membership
        }
        entries[id] = entry
        if let parentID { entries[parentID]?.children.insert(id) }
        key(keys, record)
        indexedRecords &+= 1
    }

    private mutating func key(_ keys: Keys, _ record: AnyObject) {
        switch keys {
        case .workspace(let handle, let key, let id, let resource):
            guard let workspace = record as? WorkspaceModel else { return }
            workspacesByHandle[handle] = workspace
            workspacesByID[id] = workspace
            if let key { workspacesByKey[key] = workspace }
            if let resource { workspacesByResource[resource] = workspace }
        case .screen(let handle, let resource):
            guard let screen = record as? ScreenModel else { return }
            screensByHandle[handle] = screen
            if let resource { screensByResource[resource] = screen }
        case .pane(let handle, let resource, let groups):
            guard let pane = record as? PaneModel else { return }
            panesByHandle[handle] = pane
            if let resource { panesByResource[resource] = pane }
            paneRecordsByID[pane.id, default: 0] += 1
            for group in groups { tabGroupsByID[group.id] = group }
        case .tab(let surface, let id, let terminal, let resource, let terminalResource):
            guard let tab = record as? TabModel else { return }
            tabsBySurface[surface] = tab
            recordsBySurface[surface, default: []].append(ObjectIdentifier(tab))
            tabsByID[id] = tab
            if let terminal { tabsByTerminal[terminal] = tab }
            if let resource { tabsByResource[resource] = tab }
            if let terminalResource { tabsByTerminalResource[terminalResource] = tab }
            if Self.isOverlayTab(id: id, surface: surface) { provisionalTabCount += 1 }
        }
    }

    private mutating func unkey(_ keys: Keys, _ record: AnyObject) {
        switch keys {
        case .workspace(let handle, let key, let id, let resource):
            Self.drop(handle, from: &workspacesByHandle, if: record)
            Self.drop(id, from: &workspacesByID, if: record)
            if let key { Self.drop(key, from: &workspacesByKey, if: record) }
            if let resource { Self.drop(resource, from: &workspacesByResource, if: record) }
        case .screen(let handle, let resource):
            Self.drop(handle, from: &screensByHandle, if: record)
            if let resource { Self.drop(resource, from: &screensByResource, if: record) }
        case .pane(let handle, let resource, let groups):
            Self.drop(handle, from: &panesByHandle, if: record)
            if let resource { Self.drop(resource, from: &panesByResource, if: record) }
            if let pane = record as? PaneModel, let count = paneRecordsByID[pane.id] {
                paneRecordsByID[pane.id] = count > 1 ? count - 1 : nil
            }
            for group in groups { Self.drop(group.id, from: &tabGroupsByID, if: group) }
        case .tab(let surface, let id, let terminal, let resource, let terminalResource):
            Self.drop(surface, from: &tabsBySurface, if: record)
            recordsBySurface[surface]?.removeAll { $0 == ObjectIdentifier(record) }
            if recordsBySurface[surface]?.isEmpty == true { recordsBySurface[surface] = nil }
            // A second record of the surface still indexed takes its keys back.
            if tabsBySurface[surface] == nil, let other = recordsBySurface[surface]?.first, let entry = entries[other],
               case .tab(_, let otherID, let terminal, let resource, let terminalResource) = entry.keys,
               let tab = entry.record as? TabModel {
                tabsBySurface[surface] = tab
                if tabsByID[otherID] == nil { tabsByID[otherID] = tab }
                if let terminal, tabsByTerminal[terminal] == nil { tabsByTerminal[terminal] = tab }
                if let resource, tabsByResource[resource] == nil { tabsByResource[resource] = tab }
                if let terminalResource, tabsByTerminalResource[terminalResource] == nil { tabsByTerminalResource[terminalResource] = tab }
            }
            Self.drop(id, from: &tabsByID, if: record)
            if let terminal { Self.drop(terminal, from: &tabsByTerminal, if: record) }
            if let resource { Self.drop(resource, from: &tabsByResource, if: record) }
            if let terminalResource { Self.drop(terminalResource, from: &tabsByTerminalResource, if: record) }
            if Self.isOverlayTab(id: id, surface: surface) { provisionalTabCount -= 1 }
        }
    }

    /// Whether a tab is the overlay's stand-in: a provisional id, or a provisional surface. A
    /// terminal split's stand-in carries the split's client-minted `tab_…` id, which the
    /// daemon's tab keeps, so only its surface tells it apart.
    private static func isOverlayTab(id: String, surface: SurfaceID) -> Bool {
        ProvisionalTab.isProvisional(id) || ProvisionalTab.isProvisional(surface: surface)
    }

    private static func drop<K: Hashable, V: AnyObject>(_ key: K, from map: inout [K: V], if record: AnyObject) {
        if map[key] === record { map[key] = nil }
    }
}
