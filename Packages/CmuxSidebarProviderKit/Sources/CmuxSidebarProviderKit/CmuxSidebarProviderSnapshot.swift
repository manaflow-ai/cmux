import Foundation

public struct CmuxSidebarProviderSnapshot: Codable, Equatable, Sendable {
    public var sequence: UInt64
    public var selectedWorkspaceId: UUID?
    public var workspaces: [CmuxSidebarProviderWorkspace]
    public var windowId: UUID?

    public init(
        sequence: UInt64,
        selectedWorkspaceId: UUID?,
        workspaces: [CmuxSidebarProviderWorkspace],
        windowId: UUID? = nil
    ) {
        self.sequence = sequence
        self.selectedWorkspaceId = selectedWorkspaceId
        self.workspaces = workspaces
        self.windowId = windowId
    }

    public var workspaceIds: [UUID] {
        workspaces.map(\.id)
    }
}

public struct CmuxSidebarProviderGitBranch: Codable, Equatable, Sendable {
    public var branch: String
    public var isDirty: Bool

    public init(branch: String, isDirty: Bool) {
        self.branch = branch
        self.isDirty = isDirty
    }
}

public struct CmuxSidebarProviderWorkspace: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var customDescription: String?
    public var isPinned: Bool
    public var rootPath: String?
    public var projectRootPath: String?
    public var branchSummary: String?
    public var remoteDisplayTarget: String?
    public var remoteConnectionState: String?
    public var unreadCount: Int
    public var latestNotificationText: String?
    public var latestSubmittedMessage: String?
    public var latestSubmittedAt: Date?
    public var listeningPorts: [Int]
    public var pullRequestURLs: [String]
    public var panelDirectories: [String]
    public var gitBranches: [CmuxSidebarProviderGitBranch]

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
        self.latestSubmittedMessage = latestSubmittedMessage
        self.latestSubmittedAt = latestSubmittedAt
        self.listeningPorts = listeningPorts
        self.pullRequestURLs = pullRequestURLs
        self.panelDirectories = panelDirectories
        self.gitBranches = gitBranches
    }
}
