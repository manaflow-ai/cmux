#if DEBUG
import CmuxNextDesign

nonisolated extension SidebarNestedFixture {
    static var archiveGroups: [SidebarNode] {
        func workspace(_ id: String, _ title: String, archived: Bool = false) -> SidebarWorkspace {
            var row = SidebarWorkspace(id: WorkspaceID(id), title: title)
            row.isArchived = archived
            return row
        }
        func group(_ id: String, _ title: String, _ rows: [SidebarWorkspace], parent: String? = nil) -> SidebarNode {
            var group = SidebarGroup(id: GroupID(id), name: title, color: .green, workspaces: rows)
            group.parent = parent.map(GroupID.init)
            group.depth = parent == nil ? 0 : 1
            return .group(group)
        }
        return [
            .workspace(workspace("archive-current", "Current workspace")),
            group("archive-mixed", "Design", [workspace("archive-live", "Current exploration"),
                                               workspace("archive-old", "Earlier exploration", archived: true)]),
            group("archive-all", "Completed project", [workspace("archive-draft", "First draft", archived: true),
                                                       workspace("archive-notes", "Research notes", archived: true)]),
            group("archive-child", "Follow-up", [workspace("archive-nested", "Previous approach", archived: true)], parent: "archive-all"),
            group("archive-empty", "Empty group", []),
            .workspace(workspace("archive-loose", "Ungrouped archive", archived: true)),
        ]
    }
}

extension SidebarNestedFixture {
    @MainActor package func applyArchivedFolds(_ opened: Bool?, to model: SidebarModel) {
        guard scenario == .archived, let opened else { return }
        let folds = sections.flatMap { section in
            section.nodes.compactMap { node -> SidebarDoneFoldID? in
                guard case let .group(group) = node else { return nil }
                return SidebarDoneFoldID(section: section.id, group: group.id, kind: .archived)
            }
        }
        model.openDoneFolds = opened ? Set(folds + [.archive]) : []
    }
}
#endif
