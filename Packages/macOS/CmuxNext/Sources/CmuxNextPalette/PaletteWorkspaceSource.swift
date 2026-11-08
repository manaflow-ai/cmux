

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
    /// More words that find the row: the title and session id of the one tab it holds, which
    /// Go to Workspace does not list on its own (a lone tab is its workspace).
    public var keywords: [String]
    /// The row's place in the active window's sidebar, top first (0), nil when the sidebar does not draw it.
    public var sidebarRank: Int?

    /// The words that find a workspace whose one tab Go to Workspace folds into its row (a lone
    /// tab is its workspace; Leo 2026-11-03: "some of these are way too duplicated"): the tab's
    /// shown title, its address and an agent chat's acpmux session, as its `acp:` handle and bare id.
    public static func loneTabWords(title: String?, url: String? = nil, session: String?) -> [String] {
        [title, url].compactMap { $0?.isEmpty == false ? $0 : nil }
            + NavigationPaletteProvider.sessionWords(session.map { PaletteNavigationEntry.acpPrefix + $0 })
    }

    public init(id: String, title: String, directory: String? = nil, isSelected: Bool = false, unreadCount: Int = 0,
                groupName: String? = nil, machineName: String? = nil, agentID: String? = nil, keywords: [String] = [],
                sidebarRank: Int? = nil) {
        self.keywords = keywords
        self.sidebarRank = sidebarRank
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
    /// Every workspace as a Go to Workspace row (the list page and search build it; a switch by id never does).
    var workspaces: [PaletteWorkspace] { get }
    /// Whether `id` names a workspace, by one lookup: a switch by id (a palette row, the CLI, MCP, an agent) checks
    /// its id here, never by building ``workspaces`` (O(session) in the switch's turn).
    func hasWorkspace(id: String) -> Bool
    func selectWorkspace(id: String)
    func renameWorkspace(id: String, to title: String)
    func closeWorkspace(id: String)
}

public extension PaletteWorkspaceSource {
    /// A source with no lookup of its own (tests, small fakes) answers from its list.
    func hasWorkspace(id: String) -> Bool { workspaces.contains { $0.id == id } }
}
