import Foundation

/// The cmux workspace lifecycle status, as the Mac reports it.
public enum WorkspaceStatus: String, Sendable, CaseIterable {
    case idle
    case working
    /// A permission prompt or question is waiting on the user.
    case needsAttention
    /// The agent finished and left changes to review.
    case review
    case done

    /// Workspaces the user should look at next.
    public var needsUser: Bool { self == .needsAttention || self == .review }
}

public struct WorkspaceMac: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var isOnline: Bool

    public init(id: String, name: String, isOnline: Bool) {
        self.id = id
        self.name = name
        self.isOnline = isOnline
    }
}

public struct WorkspaceTab: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case chief, terminal, browser }

    public var id: String
    public var kind: Kind
    public var title: String

    public init(id: String, kind: Kind, title: String) {
        self.id = id
        self.kind = kind
        self.title = title
    }
}

public struct WorkspaceItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var branch: String
    public var macID: String
    public var lastActivity: Date
    public var status: WorkspaceStatus
    public var isPinned: Bool
    public var unreadCount: Int
    /// The newest line from Chief or the active terminal, shown as a preview.
    public var lastMessage: String
    public var tabs: [WorkspaceTab]
    /// The tab the workspace reopens on.
    public var lastTabID: String?

    public init(
        id: String, name: String, branch: String, macID: String, lastActivity: Date,
        status: WorkspaceStatus = .idle, isPinned: Bool = false, unreadCount: Int = 0,
        lastMessage: String = "", tabs: [WorkspaceTab] = [], lastTabID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.branch = branch
        self.macID = macID
        self.lastActivity = lastActivity
        self.status = status
        self.isPinned = isPinned
        self.unreadCount = unreadCount
        self.lastMessage = lastMessage
        self.tabs = tabs
        self.lastTabID = lastTabID ?? tabs.first?.id
    }
}

public struct WorkspaceTeam: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var macs: [WorkspaceMac]

    public init(id: String, name: String, macs: [WorkspaceMac]) {
        self.id = id
        self.name = name
        self.macs = macs
    }

    public var onlineCount: Int { macs.filter(\.isOnline).count }
}
