import CmuxNextDaemon

/// Sidebar order and groups from the home session's personal state
/// (plans/cmux-next/data-model.md 1.2c, 3.2): each qualified workspace has a
/// personal position and group; groups belong to one room. Without personal
/// state (an older home daemon) the daemon's shared groups and order are
/// used, as before.
@MainActor
enum PersonalSidebar {
    /// Sections of `daemon`'s workspaces in `room`: ungrouped first, then
    /// the room's groups in order. Empty groups show under the home
    /// session's section only, so each group appears once.
    static func sections(of daemon: DaemonService, room: ProfileID, machines: MachineRegistry) -> [SidebarSection] {
        let personal = machines.local.store.personal
        guard personal.isLoaded, let session = daemon.store.registryID else { return daemon.store.sidebarSections }
        let rows = rows(of: session, personal)
        let ordered = order(WindowProfiles.workspaces(of: daemon, in: room, machines: machines), rows: rows)
        let groups = personal.groups.filter { personal.groupRooms[$0.id] == room }.sorted { $0.index < $1.index }
        let known = Set(groups.map(\.id))
        let group = { (workspace: WorkspaceModel) in rows[workspace.key?.rawValue ?? workspace.id]?.group }
        var sections = [SidebarSection(group: nil, workspaces: ordered.filter { group($0).map { !known.contains($0) } ?? true })]
        let isHome = daemon === machines.local
        for candidate in groups {
            let members = ordered.filter { group($0) == candidate.id }
            if !members.isEmpty || isHome { sections.append(SidebarSection(group: candidate, workspaces: members)) }
        }
        return sections
    }

    /// Every workspace of `daemon` in personal order (for window membership
    /// order), whatever its room.
    static func orderedIDs(of daemon: DaemonService, machines: MachineRegistry) -> [String]? {
        let personal = machines.local.store.personal
        guard personal.isLoaded, let session = daemon.store.registryID else { return nil }
        return order(daemon.store.workspaces, rows: rows(of: session, personal)).map(\.id)
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
