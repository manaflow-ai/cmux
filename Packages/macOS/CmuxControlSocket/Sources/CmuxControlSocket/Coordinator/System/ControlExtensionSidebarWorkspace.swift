public import Foundation

/// One workspace row of the `extension.sidebar.snapshot` payload (the legacy
/// `v2ExtensionSidebarWorkspacePayload` dictionary, minus the
/// coordinator-minted ref).
public struct ControlExtensionSidebarWorkspace: Sendable, Equatable {
    /// One git-branch row of the sidebar snapshot.
    public struct GitBranch: Sendable, Equatable {
        /// The branch name.
        public let branch: String
        /// Whether the working tree is dirty.
        public let isDirty: Bool

        /// Creates a git-branch row.
        ///
        /// - Parameters:
        ///   - branch: The branch name.
        ///   - isDirty: Whether the working tree is dirty.
        public init(branch: String, isDirty: Bool) {
            self.branch = branch
            self.isDirty = isDirty
        }
    }

    /// The workspace's identifier.
    public let workspaceID: UUID
    /// The workspace's index within its window's tab list.
    public let index: Int
    /// The workspace's display title.
    public let title: String
    /// The custom description, if any.
    public let description: String?
    /// Whether this is the window's selected workspace.
    public let isSelected: Bool
    /// Whether the workspace is pinned.
    public let isPinned: Bool
    /// The trimmed non-empty current directory, if any.
    public let rootPath: String?
    /// The extension-sidebar project root path, if any.
    public let projectRootPath: String?
    /// The first display-ordered git branch name, if any.
    public let branchSummary: String?
    /// The remote display target, if any.
    public let remoteDisplayTarget: String?
    /// The remote connection state's raw value.
    public let remoteConnectionStateRawValue: String
    /// The app-shaped remote status payload, bridged as a JSON value.
    public let remotePayload: JSONValue
    /// The workspace's current directory.
    public let currentDirectory: String
    /// The custom tab color hex, if any.
    public let customColor: String?
    /// The unread notification count for this workspace.
    public let unreadCount: Int
    /// The latest notification's trimmed text, if any.
    public let latestNotificationText: String?
    /// The latest conversation message, if any.
    public let latestConversationMessage: String?
    /// The latest submitted message, if any.
    public let latestSubmittedMessage: String?
    /// The latest submitted-at ISO timestamp, if any.
    public let latestSubmittedAtISO: String?
    /// The workspace's listening ports.
    public let listeningPorts: [Int]
    /// The display-ordered pull-request URLs.
    public let pullRequestURLs: [String]
    /// The display-ordered panel directories.
    public let panelDirectories: [String]
    /// The display-ordered git branches.
    public let gitBranches: [GitBranch]

    /// Creates a sidebar workspace row.
    ///
    /// - Parameters:
    ///   - workspaceID: The workspace's identifier.
    ///   - index: The index within the window's tab list.
    ///   - title: The display title.
    ///   - description: The custom description, if any.
    ///   - isSelected: Whether this is the selected workspace.
    ///   - isPinned: Whether the workspace is pinned.
    ///   - rootPath: The trimmed non-empty current directory, if any.
    ///   - projectRootPath: The extension-sidebar project root, if any.
    ///   - branchSummary: The first display-ordered branch name, if any.
    ///   - remoteDisplayTarget: The remote display target, if any.
    ///   - remoteConnectionStateRawValue: The remote connection state.
    ///   - remotePayload: The app-shaped remote status payload.
    ///   - currentDirectory: The current directory.
    ///   - customColor: The custom tab color hex, if any.
    ///   - unreadCount: The unread notification count.
    ///   - latestNotificationText: The latest notification text, if any.
    ///   - latestConversationMessage: The latest conversation message.
    ///   - latestSubmittedMessage: The latest submitted message.
    ///   - latestSubmittedAtISO: The latest submitted-at ISO timestamp.
    ///   - listeningPorts: The listening ports.
    ///   - pullRequestURLs: The pull-request URLs.
    ///   - panelDirectories: The panel directories.
    ///   - gitBranches: The git branches.
    public init(
        workspaceID: UUID,
        index: Int,
        title: String,
        description: String?,
        isSelected: Bool,
        isPinned: Bool,
        rootPath: String?,
        projectRootPath: String?,
        branchSummary: String?,
        remoteDisplayTarget: String?,
        remoteConnectionStateRawValue: String,
        remotePayload: JSONValue,
        currentDirectory: String,
        customColor: String?,
        unreadCount: Int,
        latestNotificationText: String?,
        latestConversationMessage: String?,
        latestSubmittedMessage: String?,
        latestSubmittedAtISO: String?,
        listeningPorts: [Int],
        pullRequestURLs: [String],
        panelDirectories: [String],
        gitBranches: [GitBranch]
    ) {
        self.workspaceID = workspaceID
        self.index = index
        self.title = title
        self.description = description
        self.isSelected = isSelected
        self.isPinned = isPinned
        self.rootPath = rootPath
        self.projectRootPath = projectRootPath
        self.branchSummary = branchSummary
        self.remoteDisplayTarget = remoteDisplayTarget
        self.remoteConnectionStateRawValue = remoteConnectionStateRawValue
        self.remotePayload = remotePayload
        self.currentDirectory = currentDirectory
        self.customColor = customColor
        self.unreadCount = unreadCount
        self.latestNotificationText = latestNotificationText
        self.latestConversationMessage = latestConversationMessage
        self.latestSubmittedMessage = latestSubmittedMessage
        self.latestSubmittedAtISO = latestSubmittedAtISO
        self.listeningPorts = listeningPorts
        self.pullRequestURLs = pullRequestURLs
        self.panelDirectories = panelDirectories
        self.gitBranches = gitBranches
    }
}
