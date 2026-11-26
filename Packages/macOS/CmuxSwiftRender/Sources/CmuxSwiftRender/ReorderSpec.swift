/// Describes how a `.reorderable` list persists a drag-and-drop reorder: the
/// dispatcher `method` to run on drop, the param names for the moved item's id
/// and its target index, and the ordered item ids (parallel to the node's
/// children). The host runs `method` with `[idParam: movedId, indexParam:
/// targetIndex]`, so for workspaces the cmux `workspace.reorder` command both
/// reorders and persists.
public struct ReorderSpec: Codable, Sendable, Equatable {
    public let method: String
    public let idParam: String
    public let indexParam: String
    public let itemIds: [String]

    public init(method: String, idParam: String, indexParam: String, itemIds: [String]) {
        self.method = method
        self.idParam = idParam
        self.indexParam = indexParam
        self.itemIds = itemIds
    }
}
