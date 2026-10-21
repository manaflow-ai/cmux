public extension SidebarEdits {
    /// The first group named `name` that may take every workspace `ids` (``canMove(_:toGroup:in:)``):
    /// a group of their own machine row, so another machine's workspace joins that machine's group
    /// of the name, never this Mac's. Nil when no such group is listed (the caller makes one).
    static func group(named name: String, accepting ids: [WorkspaceID], in sections: [SidebarSection]) -> GroupID? {
        sections.lazy.flatMap(\.nodes).compactMap { node -> GroupID? in
            guard case let .group(group) = node, group.name == name else { return nil }
            return group.id
        }.first { canMove(ids, toGroup: $0, in: sections) }
    }
}
