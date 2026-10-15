/// A workspace row's agent sessions, for Group by Status's elbow children
/// (`SidebarGrouping.elbowsChildren`): the acpmux names of the sessions its agent chats show, and
/// the coordinator that started one (its `mux.parent` tag, a session name). The App maps it from
/// acpmux, whatever harness runs the chat; `linking` resolves each row's `parentWorkspace`.
public nonisolated struct SidebarAgentLink: Hashable, Sendable {
    public var names: [String]
    public var parent: String?

    public init(names: [String] = [], parent: String? = nil) {
        self.names = names
        self.parent = parent
    }
}

nonisolated extension SidebarAgentLink {
    /// `sections` with each row's `parentWorkspace` resolved from the rows' links (`parents`).
    public static func linking(_ sections: [SidebarSection]) -> [SidebarSection] {
        let parents = parents(in: sections)
        // No agent started another (the usual list): the rows as they are, no copy.
        if parents.isEmpty, !sections.contains(where: { $0.workspaces.contains { $0.parentWorkspace != nil } }) { return sections }
        func linked(_ row: SidebarWorkspace) -> SidebarWorkspace {
            var row = row
            row.parentWorkspace = parents[row.id]
            return row
        }
        return sections.map { section in
            var section = section
            section.nodes = section.nodes.map { node in
                switch node {
                case let .workspace(row): return .workspace(linked(row))
                case var .group(group):
                    group.workspaces = group.workspaces.map(linked)
                    return .group(group)
                }
            }
            return section
        }
    }

    /// Whether a patch of `changed` changes a listed row's link: then another row's parent may
    /// change too, and the list resolves every row again (`linking`).
    public static func relinks(_ changed: [SidebarWorkspace], in sections: [SidebarSection]) -> Bool {
        let listed = Dictionary(sections.flatMap(\.workspaces).map { ($0.id, $0.agentLink) }, uniquingKeysWith: { first, _ in first })
        return changed.contains { row in listed[row.id].map { $0 != row.agentLink } ?? false }
    }

    /// Each listed row's parent: the first row in list order one of whose sessions has the name
    /// of the row's coordinator (`parent`). A row is never its own parent.
    public static func parents(in sections: [SidebarSection]) -> [WorkspaceID: WorkspaceID] {
        let rows = sections.flatMap(\.workspaces)
        var owners: [String: WorkspaceID] = [:]
        for row in rows {
            for name in row.agentLink?.names ?? [] where owners[name] == nil { owners[name] = row.id }
        }
        var parents: [WorkspaceID: WorkspaceID] = [:]
        for row in rows {
            guard let name = row.agentLink?.parent, let owner = owners[name], owner != row.id else { continue }
            parents[row.id] = owner
        }
        return parents
    }
}
