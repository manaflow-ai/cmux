import Foundation

extension SidebarModel {
    /// Every group the sidebar lists, in row order.
    public var groups: [SidebarGroup] {
        sections.flatMap(\.nodes).compactMap { node in
            if case let .group(group) = node { return group }
            return nil
        }
    }

    /// The group listing workspace `id`, if any.
    public func group(containing id: WorkspaceID) -> SidebarGroup? {
        groups.first { $0.workspaces.contains { $0.id == id } }
    }
}
