/// One row per workspace id. Rows are keyed by workspace id (`SidebarRowKey.workspace`), and the list keeps one
/// row view per key, so a second row with the same id drew nothing: a blank slot in the list, and the one view
/// showed either row's content. Cloud machines made from one image share that image's workspace ids, so several
/// Cloud sections listed the same id (Leo 2026-10-29: "the rendering gets borked there too :(").
nonisolated extension SidebarLayout {
    /// `sections` with each workspace id listed once, by the first section that lists it (this Mac's sections come
    /// first, so a remote copy never hides a local row). Without a repeated id, `sections` as they are.
    static func listingEachWorkspaceOnce(_ sections: [SidebarSection]) -> [SidebarSection] {
        var seen = Set<WorkspaceID>()
        var first: [WorkspaceID: SectionID] = [:]
        for section in sections {
            for ws in section.nodes.lazy.flatMap(\.workspaces) where !seen.insert(ws.id).inserted {
                first[ws.id] = first[ws.id] ?? section.id
            }
        }
        guard !first.isEmpty else { return sections }
        // The section each repeated id stays in: the first one that listed it.
        var owner: [WorkspaceID: SectionID] = [:]
        for section in sections {
            for ws in section.nodes.lazy.flatMap(\.workspaces) where first[ws.id] != nil && owner[ws.id] == nil {
                owner[ws.id] = section.id
            }
        }
        return sections.map { section in
            var section = section
            var kept = Set<WorkspaceID>()
            func keeps(_ ws: SidebarWorkspace) -> Bool {
                guard let stays = owner[ws.id] else { return true }
                return stays == section.id && kept.insert(ws.id).inserted
            }
            section.nodes = section.nodes.compactMap { node in
                switch node {
                case let .workspace(ws):
                    return keeps(ws) ? node : nil
                case var .group(group):
                    group.setMembers(group.members.filter { member in
                        if case let .workspace(ws) = member { keeps(ws) } else { true }
                    })
                    return .group(group)
                case .item:
                    return node
                }
            }
            return section
        }
    }
}
