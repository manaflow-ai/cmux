/// A sidebar group of the Mac's workspace store (`WorkspaceGroup` in
/// common.schema.json): the section a workspace is filed in. `order` is the
/// group's position among the host's groups.
public struct MobileWorkspaceGroup: Hashable, Sendable, Codable {
    public var id: String
    public var name: String
    public var order: Int?

    public init(id: String, name: String, order: Int? = nil) {
        self.id = id
        self.name = name
        self.order = order
    }
}
