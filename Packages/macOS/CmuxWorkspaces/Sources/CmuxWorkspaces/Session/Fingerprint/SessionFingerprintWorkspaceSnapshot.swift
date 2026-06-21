public import Foundation

/// The per-workspace values the session autosave fingerprint folds into its
/// hash, one per workspace within the window's session-eligible prefix.
///
/// Carries exactly what the legacy `for workspace in tabs.prefix(...)` loop in
/// `TabManager.sessionAutosaveFingerprint` combined, in order, including the
/// flattened per-panel inputs. The legacy `customTitle`/`customDescription`/
/// `customColor` `?? ""` coalescing and the `progress`/`gitBranch` optional
/// branches are reduced app-side into plain fields. The app-side
/// ``SessionFingerprintHosting`` witness builds these from the live workspace,
/// notification store, and resume/agent indexes.
public struct SessionFingerprintWorkspaceSnapshot: Sendable, Equatable {
    /// The quantized progress contribution (legacy `progress` branch).
    public struct Progress: Sendable, Equatable {
        /// Legacy `Int((progress.value * 1000).rounded())`.
        public let quantizedValue: Int
        /// Legacy `progress.label`, folded as an `Optional<String>` (not coalesced).
        public let label: String?

        /// Creates a quantized progress contribution.
        public init(quantizedValue: Int, label: String?) {
            self.quantizedValue = quantizedValue
            self.label = label
        }
    }

    /// The git-branch contribution (legacy `gitBranch` branch).
    public struct GitBranch: Sendable, Equatable {
        /// Legacy `gitBranch.branch`.
        public let branch: String
        /// Legacy `gitBranch.isDirty`.
        public let isDirty: Bool

        /// Creates a git-branch contribution.
        public init(branch: String, isDirty: Bool) {
            self.branch = branch
            self.isDirty = isDirty
        }
    }

    /// Legacy `workspace.id`.
    public let id: UUID
    /// Legacy `workspace.groupId`.
    public let groupId: UUID?
    /// Legacy `workspace.focusedPanelId`.
    public let focusedPanelId: UUID?
    /// Legacy `workspace.currentDirectory`.
    public let currentDirectory: String
    /// Legacy `workspace.customTitle ?? ""`, coalesced app-side.
    public let customTitle: String
    /// Legacy `workspace.customDescription ?? ""`, coalesced app-side.
    public let customDescription: String
    /// Legacy `workspace.customColor ?? ""`, coalesced app-side.
    public let customColor: String
    /// Legacy `workspace.isPinned`.
    public let isPinned: Bool

    // The legacy `.count`-only folds, captured as raw counts in legacy order.
    /// Legacy `workspace.panels.count`.
    public let panelsCount: Int
    /// Legacy `workspace.statusEntries.count`.
    public let statusEntriesCount: Int
    /// Legacy `workspace.metadataBlocks.count`.
    public let metadataBlocksCount: Int
    /// Legacy `workspace.logEntries.count`.
    public let logEntriesCount: Int
    /// Legacy `workspace.panelDirectories.count`.
    public let panelDirectoriesCount: Int
    /// Legacy `workspace.panelTitles.count`.
    public let panelTitlesCount: Int
    /// Legacy `workspace.panelPullRequests.count`.
    public let panelPullRequestsCount: Int
    /// Legacy `workspace.panelGitBranches.count`.
    public let panelGitBranchesCount: Int
    /// Legacy `workspace.surfaceListeningPorts.count`.
    public let surfaceListeningPortsCount: Int

    /// Legacy `notificationStore?.hasManualUnread(forTabId:) ?? false`.
    public let hasManualUnread: Bool
    /// Legacy `notificationStore?.workspaceIsUnread(forTabId:) ?? false`.
    public let workspaceIsUnread: Bool
    /// Legacy workspace-scoped `notificationStore?.notifications(forTabId:surfaceId: nil)`,
    /// flattened (service sorts and folds them).
    public let notifications: [SessionFingerprintNotificationSnapshot]

    /// Legacy sorted-`panelId` per-panel folds, in `uuidString` order.
    public let panels: [SessionFingerprintPanelSnapshot]

    /// Legacy `workspace.progress` contribution, or nil for the `-1` else branch.
    public let progress: Progress?
    /// Legacy `workspace.gitBranch` contribution, or nil for the empty else branch.
    public let gitBranch: GitBranch?

    /// Creates a flattened per-workspace fingerprint input.
    public init(
        id: UUID,
        groupId: UUID?,
        focusedPanelId: UUID?,
        currentDirectory: String,
        customTitle: String,
        customDescription: String,
        customColor: String,
        isPinned: Bool,
        panelsCount: Int,
        statusEntriesCount: Int,
        metadataBlocksCount: Int,
        logEntriesCount: Int,
        panelDirectoriesCount: Int,
        panelTitlesCount: Int,
        panelPullRequestsCount: Int,
        panelGitBranchesCount: Int,
        surfaceListeningPortsCount: Int,
        hasManualUnread: Bool,
        workspaceIsUnread: Bool,
        notifications: [SessionFingerprintNotificationSnapshot],
        panels: [SessionFingerprintPanelSnapshot],
        progress: Progress?,
        gitBranch: GitBranch?
    ) {
        self.id = id
        self.groupId = groupId
        self.focusedPanelId = focusedPanelId
        self.currentDirectory = currentDirectory
        self.customTitle = customTitle
        self.customDescription = customDescription
        self.customColor = customColor
        self.isPinned = isPinned
        self.panelsCount = panelsCount
        self.statusEntriesCount = statusEntriesCount
        self.metadataBlocksCount = metadataBlocksCount
        self.logEntriesCount = logEntriesCount
        self.panelDirectoriesCount = panelDirectoriesCount
        self.panelTitlesCount = panelTitlesCount
        self.panelPullRequestsCount = panelPullRequestsCount
        self.panelGitBranchesCount = panelGitBranchesCount
        self.surfaceListeningPortsCount = surfaceListeningPortsCount
        self.hasManualUnread = hasManualUnread
        self.workspaceIsUnread = workspaceIsUnread
        self.notifications = notifications
        self.panels = panels
        self.progress = progress
        self.gitBranch = gitBranch
    }
}
