

public struct PaletteWorkspace: Identifiable, Sendable, Hashable {
    public let id: String
    public var title: String
    public var directory: String?
    public var isSelected: Bool
    public var unreadCount: Int
    /// The sidebar group the workspace is in, or nil.
    public var groupName: String?
    /// The machine the workspace runs on, while more than one is listed (machine identity): the
    /// row's subtitle leads with it, and typing its name finds its workspaces.
    public var machineName: String?

    public init(id: String, title: String, directory: String? = nil, isSelected: Bool = false, unreadCount: Int = 0,
                groupName: String? = nil, machineName: String? = nil) {
        self.machineName = machineName
        self.id = id
        self.title = title
        self.directory = directory
        self.isSelected = isSelected
        self.unreadCount = unreadCount
        self.groupName = groupName
    }
}

public protocol PaletteWorkspaceSource: AnyObject {
    var workspaces: [PaletteWorkspace] { get }
    func selectWorkspace(id: String)
    func renameWorkspace(id: String, to title: String)
    func closeWorkspace(id: String)
}
