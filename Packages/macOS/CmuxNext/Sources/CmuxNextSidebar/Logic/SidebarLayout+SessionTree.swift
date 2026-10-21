import Foundation

nonisolated extension SidebarLayout {
    /// The session tree's drawn order of one list (a section's loose rows, or a group's members):
    /// each entry's model index and depth. A workspace whose `parents` entry is another workspace of
    /// the same list draws right after it at depth 1, in their own order; under a child's child
    /// it still draws at depth 1, under the top one (one level, as acpmux keeps `spawnedBy`). A
    /// parent in another list leaves the row where it is, and so does a cycle. `ids` are the
    /// entries' workspaces (nil: a group or an item). Without `parents` the order is the model's.
    static func treeOrder(_ ids: [WorkspaceID?], parents: [WorkspaceID: WorkspaceID]?) -> [(index: Int, depth: Int)] {
        guard let parents, !parents.isEmpty else { return ids.indices.map { ($0, 0) } }
        let present = Set(ids.compactMap { $0 })
        func root(_ id: WorkspaceID) -> WorkspaceID? {
            var seen: Set<WorkspaceID> = [id]
            var current = id
            while let parent = parents[current], present.contains(parent) {
                guard seen.insert(parent).inserted else { return nil }
                current = parent
            }
            return current == id ? nil : current
        }
        var children: [WorkspaceID: [Int]] = [:]
        var nested: Set<Int> = []
        for (index, id) in ids.enumerated() {
            guard let id, let top = root(id) else { continue }
            children[top, default: []].append(index)
            nested.insert(index)
        }
        var order: [(index: Int, depth: Int)] = []
        order.reserveCapacity(ids.count)
        for (index, id) in ids.enumerated() where !nested.contains(index) {
            order.append((index, 0))
            if let id { order += (children[id] ?? []).map { ($0, 1) } }
        }
        return order
    }

    /// The workspace of each node (nil: a group or an item), for `treeOrder`.
    static func workspaceIDs(_ nodes: [SidebarNode]) -> [WorkspaceID?] {
        nodes.map { node in if case let .workspace(ws) = node { ws.id } else { nil } }
    }

    /// The workspace of each group member (nil: an item), for `treeOrder`.
    static func workspaceIDs(_ members: [SidebarGroupMember]) -> [WorkspaceID?] {
        members.map { member in if case let .workspace(ws) = member { ws.id } else { nil } }
    }
}
