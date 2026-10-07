

public struct PaletteWorkspace: Identifiable, Sendable, Hashable {
    public let id: String
    public var title: String
    public var directory: String?
    public var isSelected: Bool
    public var unreadCount: Int

    public init(id: String, title: String, directory: String? = nil, isSelected: Bool = false, unreadCount: Int = 0) {
        self.id = id
        self.title = title
        self.directory = directory
        self.isSelected = isSelected
        self.unreadCount = unreadCount
    }
}

public protocol PaletteWorkspaceSource: AnyObject {
    var workspaces: [PaletteWorkspace] { get }
    func selectWorkspace(id: String)
    func renameWorkspace(id: String, to title: String)
    func closeWorkspace(id: String)
}
