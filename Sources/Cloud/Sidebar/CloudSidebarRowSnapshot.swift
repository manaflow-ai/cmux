/// Sendable socket projection of the real sidebar. Captured on the main actor;
/// JSON serialization stays on the socket worker.
struct CloudSidebarRowSnapshot: Codable, Sendable {
    let id: String
    let title: String
    let kind: String
    let pinned: Bool
    let canOrganize: Bool
    let children: [CloudSidebarRowSnapshot]

    private enum CodingKeys: String, CodingKey {
        case id, title, kind, pinned, children
        case canOrganize = "can_organize"
    }

    @MainActor
    init(node: CloudTreeNode) {
        id = node.id
        title = node.searchableTitle
        kind = node.structureTag
        pinned = node.isPinned
        canOrganize = node.canOrganize
        children = node.children.map { CloudSidebarRowSnapshot(node: $0) }
    }
}
