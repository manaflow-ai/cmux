import CmuxNextBridge
import CmuxNextDaemon

/// Sidebar order and groups from the home session's personal state
/// (plans/cmux-next/data-model.md 1.2c, 3.2): each qualified workspace has a
/// personal position and group; groups belong to one room. Without personal
/// state (an older home daemon) the daemon's shared groups and order are
/// used, as before.
@MainActor
enum PersonalSidebar {
    /// Sections of `daemon`'s workspaces in `room`: ungrouped first, then
    /// the room's groups in order. With `personal-mixed-order-v1` on the
    /// home session each group shows at its `top_index` among the loose
    /// workspaces instead (`mixedSections`). Empty groups show under the
    /// home session's section only, so each group appears once; an empty
    /// group being deleted (`PersonalStore.endingGroups`) does not show.
    /// `doc`: the app's sidebar document (sidebar-v2), which orders the rows while it is shown.
    static func sections(of daemon: DaemonService, room: ProfileID, machines: MachineRegistry, doc: SidebarDocument) -> [SidebarSection] {
        if let sections = doc.sections(of: daemon, room: room, machines: machines) { return sections } // the sidebar document (sidebar-v2)
        let personal = machines.local.store.personal
        guard personal.isLoaded, let session = daemon.store.registryID else { return daemon.store.sidebarSections }
        let groups = personal.groups.filter { personal.groupRooms[$0.id] == room }.sorted { $0.index < $1.index }
        let workspaces = WindowProfiles.workspaces(of: daemon, in: room, machines: machines)
        let isHome = daemon === machines.local
        if machines.local.store.supportsPersonalMixedOrder {
            return mixedSections(workspaces, groups: groups, session: session, personal: personal, keepsEmptyGroups: isHome,
                                 newRowsFirst: newRowsFirst(daemon, machines, doc))
        }
        let rows = rows(of: session, personal)
        let ordered = order(workspaces, rows: rows, orderedRows: personal.workspacesInOrder)
        let known = Set(groups.map(\.id))
        let group = { (workspace: WorkspaceModel) in rows[workspace.key?.rawValue ?? workspace.id]?.group }
        var sections = [SidebarSection(group: nil, workspaces: ordered.filter { group($0).map { !known.contains($0) } ?? true })]
        for candidate in groups {
            let members = ordered.filter { group($0) == candidate.id }
            if !members.isEmpty || isHome && !personal.endingGroups.contains(candidate.id) {
                sections.append(SidebarSection(group: candidate, workspaces: members))
            }
        }
        return sections
    }

    /// Every workspace of `daemon` in personal order (for window membership
    /// order), whatever its room; in the shown (mixed) order with
    /// `personal-mixed-order-v1`.
    static func orderedIDs(of daemon: DaemonService, machines: MachineRegistry, doc: SidebarDocument) -> [String]? {
        // The sidebar document orders the rows: never the personal (`workspace_placement`) order on its path.
        if let ordered = doc.orderedIDs(of: daemon, machines: machines) { return ordered }
        let personal = machines.local.store.personal
        guard personal.isLoaded, let session = daemon.store.registryID else { return nil }
        if machines.local.store.supportsPersonalMixedOrder {
            let groups = personal.groups.sorted { $0.index < $1.index }
            return mixedSections(daemon.store.workspaces, groups: groups, session: session, personal: personal, keepsEmptyGroups: false,
                                 newRowsFirst: newRowsFirst(daemon, machines, doc))
                .flatMap(\.workspaces).map(\.id)
        }
        return order(daemon.store.workspaces, rows: rows(of: session, personal),
                     orderedRows: personal.workspacesInOrder).map(\.id)
    }

    /// The daemon's mixed order (`sidebar_workspace_ids` in cmux-tui
    /// `state/personal_order.rs`) over `workspaces` of `session`: walk every
    /// personal row by position; before row i come the groups whose
    /// `top_index` is i (in group order, members in personal order), then
    /// row i when it is loose. Workspaces without a personal row follow as
    /// loose rows, then the groups placed after every loose row (`top_index`
    /// nil or past the last row). Consecutive loose rows share one section.
    /// `newRowsFirst`: those workspaces are creates whose row is on the way
    /// (this Mac's daemon writes one in every create), listed first below
    /// Home, newest first, where the row will put them (sidebar-ordering-DESIGN.md).
    static func mixedSections(_ workspaces: [WorkspaceModel], groups: [WorkspaceGroupModel], session: String,
                              personal: PersonalStore, keepsEmptyGroups: Bool, newRowsFirst: Bool = false) -> [SidebarSection] {
        let all = personal.workspacesInOrder // sorted once per change of the list, not on every pass
        let rows = rows(of: session, personal)
        let ordered = order(workspaces, rows: rows, orderedRows: personal.workspacesInOrder)
        let known = Set(groups.map(\.id))
        let byKey = Dictionary(ordered.map { (rowKey($0), $0) }, uniquingKeysWith: { first, _ in first })
        // One pass each (O(n + groups)), not a scan of every workspace per group or of every group per row.
        let membersByGroup = Dictionary(grouping: ordered.filter { rows[rowKey($0)]?.group != nil }) { rows[rowKey($0)]?.group }
        let groupsAt = Dictionary(grouping: groups.filter { $0.topIndex != nil }) { $0.topIndex }
        var sections: [SidebarSection] = []
        var loose: [WorkspaceModel] = []
        func emit(_ group: WorkspaceGroupModel) {
            let members = membersByGroup[group.id] ?? []
            // A group being deleted for losing its last member stays hidden (PersonalGroupLife.commit).
            guard !members.isEmpty || keepsEmptyGroups && !personal.endingGroups.contains(group.id) else { return }
            if !loose.isEmpty { sections.append(SidebarSection(group: nil, workspaces: loose)) }
            loose = []
            sections.append(SidebarSection(group: group, workspaces: members))
        }
        for (index, row) in all.enumerated() {
            for group in groupsAt[index] ?? [] { emit(group) }
            if row.sessionID == session, let workspace = byKey[row.workspaceKey.rawValue],
               rows[rowKey(workspace)]?.group.map({ !known.contains($0) }) ?? true {
                loose.append(workspace)
            }
        }
        let fresh = ordered.filter { rows[rowKey($0)] == nil }
        if !newRowsFirst { loose += fresh }
        for group in groups where group.topIndex.map({ $0 >= all.count }) ?? true { emit(group) }
        if !loose.isEmpty || sections.isEmpty { sections.append(SidebarSection(group: nil, workspaces: loose)) }
        if newRowsFirst, !fresh.isEmpty {
            if sections.count == 1, sections[0].group == nil, sections[0].workspaces.isEmpty { sections = [] }
            SidebarDocSections.insertFirst(Array(fresh.reversed()), into: &sections, machineSections: sections.count)
        }
        return sections
    }

    /// Whether `daemon`'s workspaces without a personal row yet are creates that list first: this Mac's
    /// daemon writes a row in every create (`workspaces.newPlacement` `top`); another machine's does not.
    private static func newRowsFirst(_ daemon: DaemonService, _ machines: MachineRegistry, _ doc: SidebarDocument) -> Bool {
        daemon === machines.local && doc.docSections.placesNewRowsFirst()
    }

    /// The personal order of every qualified workspace, as `session/key`.
    static func globalOrder(_ personal: PersonalStore) -> [String] {
        personal.workspacesInOrder.map { "\($0.sessionID)/\($0.workspaceKey.rawValue)" }
    }

    /// A workspace's key in the personal rows (its stable key, else its id).
    private static func rowKey(_ workspace: WorkspaceModel) -> String {
        workspace.key?.rawValue ?? workspace.id
    }

    /// The store's index of `session`'s rows (first row of a key wins), not a filter of every session's rows per pass.
    private static func rows(of session: String, _ personal: PersonalStore) -> [String: PersonalWorkspace] {
        personal.workspaces(session: session)
    }

    /// `workspaces` of `daemon` in personal order; unchanged without personal state. On the sidebar
    /// document the rows it does not place yet follow in this order (RapidWorkspaceCreateTests). On this
    /// Mac's daemon under `top`, the ones without a personal row yet (creates whose row is on the way)
    /// come first below Home, in the given order, where their row will put them.
    static func personalOrder(_ workspaces: [WorkspaceModel], of daemon: DaemonService, machines: MachineRegistry,
                              doc: SidebarDocument) -> [WorkspaceModel] {
        let personal = machines.local.store.personal
        guard personal.isLoaded, let session = daemon.store.registryID else { return workspaces }
        let rows = rows(of: session, personal)
        let ordered = order(workspaces, rows: rows, orderedRows: personal.workspacesInOrder)
        guard newRowsFirst(daemon, machines, doc) else { return ordered }
        let fresh = ordered.filter { rows[rowKey($0)] == nil }
        guard !fresh.isEmpty else { return ordered }
        var placed = ordered.filter { rows[rowKey($0)] != nil }
        placed.insert(contentsOf: fresh, at: placed.first?.kind == SidebarMapping.homeKind ? 1 : 0)
        return placed
    }

    /// Rowed workspaces by personal position, then the rest in daemon order.
    /// `PersonalStore.workspacesInOrder` is sorted once when personal state changes. Walking that
    /// projection makes each sidebar pass O(n), instead of reading each tracked workspace key in
    /// an O(n log n) comparator (260-280 ms per reconcile at 1,000 workspaces).
    static func order(_ workspaces: [WorkspaceModel], rows: [String: PersonalWorkspace],
                      orderedRows: [PersonalWorkspace]) -> [WorkspaceModel] {
        guard !workspaces.isEmpty else { return [] }
        var byKey = Dictionary(workspaces.map { (rowKey($0), $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var ordered: [WorkspaceModel] = []
        ordered.reserveCapacity(workspaces.count)
        for personal in orderedRows {
            let key = personal.workspaceKey.rawValue
            guard let row = rows[key], row == personal, seen.insert(key).inserted, let workspace = byKey.removeValue(forKey: key) else { continue }
            ordered.append(workspace)
        }
        // Rows with no personal position retain the daemon's order.
        ordered.append(contentsOf: workspaces.filter { byKey[rowKey($0)] != nil })
        return ordered
    }
}
