import Foundation

/// Workspace model exposed to in-process sidebar providers.
public struct CmuxSidebarProviderWorkspace: Identifiable, Codable, Equatable, Sendable {
    /// Workspace id.
    public var id: UUID
    /// Display title.
    public var title: String
    /// Optional custom description.
    public var customDescription: String?
    /// Whether the workspace is pinned.
    public var isPinned: Bool
    /// Workspace root path.
    public var rootPath: String?
    /// Project root path.
    public var projectRootPath: String?
    /// Current git branch summary.
    public var branchSummary: String?
    /// Remote target label, if connected to a remote backend.
    public var remoteDisplayTarget: String?
    /// Remote connection state label.
    public var remoteConnectionState: String?
    /// Unread event count.
    public var unreadCount: Int
    /// Latest notification text.
    public var latestNotificationText: String?
    /// Creation time of the latest notification, if any.
    public var latestNotificationCreatedAt: Date?
    /// Whether the latest notification is still unread.
    public var latestNotificationIsUnread: Bool?
    /// Latest submitted prompt text.
    public var latestSubmittedMessage: String?
    /// Timestamp for the latest submitted prompt.
    public var latestSubmittedAt: Date?
    /// Listening ports detected in the workspace.
    public var listeningPorts: [Int]
    /// Pull request URLs associated with the workspace.
    public var pullRequestURLs: [String]
    /// Panel working directories associated with the workspace.
    public var panelDirectories: [String]
    /// Git branches detected in workspace panel directories.
    public var gitBranches: [CmuxSidebarProviderGitBranch]

    /// Creates a provider workspace snapshot.
    public init(
        id: UUID,
        title: String,
        customDescription: String?,
        isPinned: Bool,
        rootPath: String?,
        projectRootPath: String?,
        branchSummary: String?,
        remoteDisplayTarget: String?,
        remoteConnectionState: String?,
        unreadCount: Int,
        latestNotificationText: String?,
        latestNotificationCreatedAt: Date? = nil,
        latestNotificationIsUnread: Bool = false,
        latestSubmittedMessage: String? = nil,
        latestSubmittedAt: Date? = nil,
        listeningPorts: [Int],
        pullRequestURLs: [String] = [],
        panelDirectories: [String] = [],
        gitBranches: [CmuxSidebarProviderGitBranch] = []
    ) {
        self.id = id
        self.title = title
        self.customDescription = customDescription
        self.isPinned = isPinned
        self.rootPath = rootPath
        self.projectRootPath = projectRootPath
        self.branchSummary = branchSummary
        self.remoteDisplayTarget = remoteDisplayTarget
        self.remoteConnectionState = remoteConnectionState
        self.unreadCount = unreadCount
        self.latestNotificationText = latestNotificationText
        self.latestNotificationCreatedAt = latestNotificationCreatedAt
        self.latestNotificationIsUnread = latestNotificationIsUnread
        self.latestSubmittedMessage = latestSubmittedMessage
        self.latestSubmittedAt = latestSubmittedAt
        self.listeningPorts = listeningPorts
        self.pullRequestURLs = pullRequestURLs
        self.panelDirectories = panelDirectories
        self.gitBranches = gitBranches
    }
}
