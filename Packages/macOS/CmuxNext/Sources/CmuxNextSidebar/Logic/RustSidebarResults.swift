import Foundation

nonisolated struct RustTarget: Decodable {
    var kind: String; var section: RustSectionID?; var group: String?; var index: Int?; var workspace: String?
    var swiftValue: DropTarget? {
        switch kind {
        case "position":
            guard let section = section?.swiftValue, let index else { return nil }
            return .position(DropPosition(section: section, group: group.map(GroupID.init), index: index))
        case "into_group": return group.map(GroupID.init).map(DropTarget.intoGroup)
        case "onto_workspace": return workspace.map(WorkspaceID.init).map(DropTarget.ontoWorkspace)
        default: return nil
        }
    }
}

/// `resolve_drag`'s answer: the drop (nil: no slot) and the card point that decided it.
nonisolated struct RustDrag: Decodable {
    var target: RustTarget?; var probe: String
    var swiftProbe: DropResolver.DragProbe? { switch probe { case "centre": .centre; case "leading_edge": .leadingEdge; default: nil } }
}

nonisolated struct RustTabDrop: Decodable {
    var kind: String; var workspace: String?; var section: RustSectionID?; var group: String?; var index: Int?
    var swiftValue: SidebarTabDrop? { switch kind { case "into_workspace": return workspace.map(WorkspaceID.init).map(SidebarTabDrop.intoWorkspace); case "new_workspace": guard let section = section?.swiftValue, let index else { return nil }; return .newWorkspace(section: section, group: group.map(GroupID.init), index: index); case "into_group": return group.map(GroupID.init).map(SidebarTabDrop.intoGroup); default: return nil } }
}

nonisolated struct RustTabRefusal: Decodable {
    var row: RustRowKey; var reason: String
    var swiftReason: SidebarTabDropRefusal? { switch reason { case "other_machine": .otherMachine; case "pinned_area": .pinnedArea; default: nil } }
}
