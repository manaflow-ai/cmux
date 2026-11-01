

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
    /// The short id a Chief knows the workspace's subagent by (`a612`), nil for other workspaces:
    /// the row's subtitle leads with it, and typing it (or its digits) puts the row first.
    public var agentID: String?

    public init(id: String, title: String, directory: String? = nil, isSelected: Bool = false, unreadCount: Int = 0,
                groupName: String? = nil, machineName: String? = nil, agentID: String? = nil) {
        self.machineName = machineName
        self.agentID = agentID
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
