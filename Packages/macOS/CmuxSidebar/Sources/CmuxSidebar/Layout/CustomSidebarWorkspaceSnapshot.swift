public import CmuxSwiftRender
public import Foundation

/// One workspace projected for the custom-sidebar interpreter context, in
/// sidebar display order.
///
/// The app resolves each field from live workspace state; the data-context
/// builder maps it to the `workspaces[i]` value object. Optional fields are
/// `nil` when absent so interpreted `if let` / ternary truthiness behaves, and
/// empty strings on the optional text fields are treated the same as `nil`.
public struct CustomSidebarWorkspaceSnapshot: Sendable, Equatable {
    /// Progress projected to the `workspaces[i].progress` object.
    public struct Progress: Sendable, Equatable {
        /// The fractional progress value (`progress.value`).
        public let value: Double
        /// An optional human label (`progress.label`); omitted when `nil`.
        public let label: String?

        /// Creates a progress projection.
        public init(value: Double, label: String?) {
            self.value = value
            self.label = label
        }
    }

    /// Remote-connection state projected to the `workspaces[i].remote` object.
    public struct Remote: Sendable, Equatable {
        /// The remote display target (`remote.target`).
        public let target: String
        /// The raw connection-state string (`remote.state`).
        public let stateRawValue: String
        /// Whether the workspace is currently connected (`remote.connected`).
        public let isConnected: Bool

        /// Creates a remote projection.
        public init(target: String, stateRawValue: String, isConnected: Bool) {
            self.target = target
            self.stateRawValue = stateRawValue
            self.isConnected = isConnected
        }
    }

    /// The workspace identifier, projected to `workspaces[i].id`.
    public let id: UUID
    /// The display title (custom title falling back to the live title).
    public let title: String
    /// Whether this workspace is the selected one (`workspaces[i].selected`).
    public let isSelected: Bool
    /// Whether the workspace is pinned (`workspaces[i].pinned`).
    public let isPinned: Bool
    /// The zero-based sidebar position (`workspaces[i].index`).
    public let index: Int
    /// The workspace's current directory (`workspaces[i].directory`).
    public let directory: String
    /// The workspace's listening ports (`workspaces[i].ports` / `.portCount`).
    public let listeningPorts: [Int]
    /// The workspace's unread count (`workspaces[i].unread`).
    public let unreadCount: Int
    /// Surfaces in pane order (`workspaces[i].tabs`).
    public let surfaces: [CustomSidebarSurfaceSnapshot]
    /// Total surface count across panes (`workspaces[i].tabCount`).
    public let surfaceCount: Int
    /// Custom description; omitted when `nil`/empty (`workspaces[i].description`).
    public let customDescription: String?
    /// Custom color hex; omitted when `nil`/empty (`workspaces[i].color`).
    public let customColor: String?
    /// The first sidebar git branch name (`workspaces[i].branch`).
    public let gitBranch: String?
    /// Whether that branch is dirty (`workspaces[i].dirty`); only meaningful
    /// when ``gitBranch`` is non-nil.
    public let gitIsDirty: Bool
    /// Pull-request value objects already projected in display order, mapped to
    /// `workspaces[i].pr` (first) and `workspaces[i].prs` (all).
    public let pullRequestValues: [SwiftValue]
    /// Progress projection; omitted when `nil` (`workspaces[i].progress`).
    public let progress: Progress?
    /// Latest conversation message; omitted when `nil`/empty
    /// (`workspaces[i].latestMessage`).
    public let latestConversationMessage: String?
    /// Latest submitted prompt; omitted when `nil`/empty
    /// (`workspaces[i].latestPrompt`).
    public let latestSubmittedMessage: String?
    /// Latest submission time; omitted when `nil` (`workspaces[i].latestAt`).
    public let latestSubmittedAt: Date?
    /// Remote projection; omitted when `nil` (`workspaces[i].remote`).
    public let remote: Remote?

    /// Creates a workspace snapshot from already-resolved leaf values.
    public init(
        id: UUID,
        title: String,
        isSelected: Bool,
        isPinned: Bool,
        index: Int,
        directory: String,
        listeningPorts: [Int],
        unreadCount: Int,
        surfaces: [CustomSidebarSurfaceSnapshot],
        surfaceCount: Int,
        customDescription: String?,
        customColor: String?,
        gitBranch: String?,
        gitIsDirty: Bool,
        pullRequestValues: [SwiftValue],
        progress: Progress?,
        latestConversationMessage: String?,
        latestSubmittedMessage: String?,
        latestSubmittedAt: Date?,
        remote: Remote?
    ) {
        self.id = id
        self.title = title
        self.isSelected = isSelected
        self.isPinned = isPinned
        self.index = index
        self.directory = directory
        self.listeningPorts = listeningPorts
        self.unreadCount = unreadCount
        self.surfaces = surfaces
        self.surfaceCount = surfaceCount
        self.customDescription = customDescription
        self.customColor = customColor
        self.gitBranch = gitBranch
        self.gitIsDirty = gitIsDirty
        self.pullRequestValues = pullRequestValues
        self.progress = progress
        self.latestConversationMessage = latestConversationMessage
        self.latestSubmittedMessage = latestSubmittedMessage
        self.latestSubmittedAt = latestSubmittedAt
        self.remote = remote
    }
}
