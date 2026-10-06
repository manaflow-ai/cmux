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
    /// home session's section only, so each group appears once.
    static func sections(of daemon: DaemonService, room: ProfileID, machines: MachineRegistry) -> [SidebarSection] {
        let personal = machines.local.store.personal
        guard personal.isLoaded, let session = daemon.store.registryID else { return daemon.store.sidebarSections }
        let groups = personal.groups.filter { personal.groupRooms[$0.id] == room }.sorted { $0.index < $1.index }
        let workspaces = WindowProfiles.workspaces(of: daemon, in: room, machines: machines)
        let isHome = daemon === machines.local
        if machines.local.store.supportsPersonalMixedOrder {
            return mixedSections(workspaces, groups: groups, session: session, personal: personal, keepsEmptyGroups: isHome)
        }
        let rows = rows(of: session, personal)
        let ordered = order(workspaces, rows: rows)
        let known = Set(groups.map(\.id))
        let group = { (workspace: WorkspaceModel) in rows[workspace.key?.rawValue ?? workspace.id]?.group }
        var sections = [SidebarSection(group: nil, workspaces: ordered.filter { group($0).map { !known.contains($0) } ?? true })]
        for candidate in groups {
            let members = ordered.filter { group($0) == candidate.id }
            if !members.isEmpty || isHome { sections.append(SidebarSection(group: candidate, workspaces: members)) }
        }
        return sections
    }

    /// Every workspace of `daemon` in personal order (for window membership
    /// order), whatever its room; in the shown (mixed) order with
    /// `personal-mixed-order-v1`.
    static func orderedIDs(of daemon: DaemonService, machines: MachineRegistry) -> [String]? {
        let personal = machines.local.store.personal
        guard personal.isLoaded, let session = daemon.store.registryID else { return nil }
        if machines.local.store.supportsPersonalMixedOrder {
            let groups = personal.groups.sorted { $0.index < $1.index }
            return mixedSections(daemon.store.workspaces, groups: groups, session: session, personal: personal, keepsEmptyGroups: false)
                .flatMap(\.workspaces).map(\.id)
        }
        return order(daemon.store.workspaces, rows: rows(of: session, personal)).map(\.id)
    }

    /// The daemon's mixed order (`sidebar_workspace_ids` in cmux-tui
    /// `state/personal_order.rs`) over `workspaces` of `session`: walk every
    /// personal row by position; before row i come the groups whose
    /// `top_index` is i (in group order, members in personal order), then
    /// row i when it is loose. Workspaces without a personal row follow as
    /// loose rows, then the groups placed after every loose row (`top_index`
    /// nil or past the last row). Consecutive loose rows share one section.
    static func mixedSections(_ workspaces: [WorkspaceModel], groups: [WorkspaceGroupModel], session: String,
                              personal: PersonalStore, keepsEmptyGroups: Bool) -> [SidebarSection] {
        let all = personal.workspaces.sorted { $0.index < $1.index }
        let rows = rows(of: session, personal)
        let ordered = order(workspaces, rows: rows)
        let known = Set(groups.map(\.id))
        let key = { (workspace: WorkspaceModel) in workspace.key?.rawValue ?? workspace.id }
        let isLoose = { (workspace: WorkspaceModel) in rows[key(workspace)]?.group.map { !known.contains($0) } ?? true }
        let byKey = Dictionary(ordered.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
        var sections: [SidebarSection] = []
        var loose: [WorkspaceModel] = []
        func emit(_ group: WorkspaceGroupModel) {
            let members = ordered.filter { rows[key($0)]?.group == group.id }
            guard !members.isEmpty || keepsEmptyGroups else { return }
            if !loose.isEmpty { sections.append(SidebarSection(group: nil, workspaces: loose)) }
            loose = []
            sections.append(SidebarSection(group: group, workspaces: members))
        }
        for (index, row) in all.enumerated() {
            for group in groups where group.topIndex == index { emit(group) }
            if row.sessionID == session, let workspace = byKey[row.workspaceKey.rawValue], isLoose(workspace) { loose.append(workspace) }
        }
        loose += ordered.filter { rows[key($0)] == nil }
        for group in groups where group.topIndex.map({ $0 >= all.count }) ?? true { emit(group) }
        if !loose.isEmpty || sections.isEmpty { sections.append(SidebarSection(group: nil, workspaces: loose)) }
        return sections
    }

    /// The personal order of every qualified workspace, as `session/key`.
    static func globalOrder(_ personal: PersonalStore) -> [String] {
        personal.workspaces.sorted { $0.index < $1.index }.map { "\($0.sessionID)/\($0.workspaceKey.rawValue)" }
    }

    private static func rows(of session: String, _ personal: PersonalStore) -> [String: PersonalWorkspace] {
        Dictionary(personal.workspaces.filter { $0.sessionID == session }.map { ($0.workspaceKey.rawValue, $0) },
                   uniquingKeysWith: { first, _ in first })
    }

    /// Rowed workspaces by personal position, then the rest in daemon order.
    private static func order(_ workspaces: [WorkspaceModel], rows: [String: PersonalWorkspace]) -> [WorkspaceModel] {
        workspaces.enumerated().sorted { lhs, rhs in
            let l = rows[lhs.element.key?.rawValue ?? lhs.element.id]?.index
            let r = rows[rhs.element.key?.rawValue ?? rhs.element.id]?.index
            switch (l, r) {
            case let (l?, r?): return l == r ? lhs.offset < rhs.offset : l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }
}
