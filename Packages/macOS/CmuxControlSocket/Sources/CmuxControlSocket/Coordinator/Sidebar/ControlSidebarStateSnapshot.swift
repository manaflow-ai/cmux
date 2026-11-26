public import Foundation

/// A Sendable snapshot of one workspace's full sidebar context for the v1
/// `sidebar_state` listing (the coordinator formats every line from it).
public struct ControlSidebarStateSnapshot: Sendable, Equatable {
    /// The workspace (tab) id.
    public let tabID: UUID
    /// The custom sidebar color token, if any.
    public let customColor: String?
    /// The workspace-level working directory.
    public let currentDirectory: String
    /// The focused panel and its directory, when both are known.
    public let focusedPanel: ControlSidebarFocusedPanelInfo?
    /// The reported git branch state, if any.
    public let gitBranch: ControlSidebarGitBranchInfo?
    /// The first pull request in display order, if any.
    public let firstPullRequest: ControlSidebarPullRequestInfo?
    /// The aggregated listening ports.
    public let listeningPorts: [Int]
    /// The progress state, if any.
    public let progress: ControlSidebarProgressInfo?
    /// Status entries in display order.
    public let statusEntries: [ControlSidebarStatusEntrySnapshot]
    /// Metadata blocks in display order.
    public let metadataBlocks: [ControlSidebarMetadataBlockSnapshot]
    /// The total log entry count.
    public let logCount: Int
    /// The most recent log entries (last 5, oldest first).
    public let recentLogEntries: [ControlSidebarLogEntrySnapshot]

    /// Creates a snapshot.
    ///
    /// - Parameters:
    ///   - tabID: The workspace (tab) id.
    ///   - customColor: The custom sidebar color token, if any.
    ///   - currentDirectory: The workspace-level working directory.
    ///   - focusedPanel: The focused panel and its directory, when both known.
    ///   - gitBranch: The reported git branch state, if any.
    ///   - firstPullRequest: The first pull request in display order, if any.
    ///   - listeningPorts: The aggregated listening ports.
    ///   - progress: The progress state, if any.
    ///   - statusEntries: Status entries in display order.
    ///   - metadataBlocks: Metadata blocks in display order.
    ///   - logCount: The total log entry count.
    ///   - recentLogEntries: The most recent log entries (last 5).
    public init(
        tabID: UUID,
        customColor: String?,
        currentDirectory: String,
        focusedPanel: ControlSidebarFocusedPanelInfo?,
        gitBranch: ControlSidebarGitBranchInfo?,
        firstPullRequest: ControlSidebarPullRequestInfo?,
        listeningPorts: [Int],
        progress: ControlSidebarProgressInfo?,
        statusEntries: [ControlSidebarStatusEntrySnapshot],
        metadataBlocks: [ControlSidebarMetadataBlockSnapshot],
        logCount: Int,
        recentLogEntries: [ControlSidebarLogEntrySnapshot]
    ) {
        self.tabID = tabID
        self.customColor = customColor
        self.currentDirectory = currentDirectory
        self.focusedPanel = focusedPanel
        self.gitBranch = gitBranch
        self.firstPullRequest = firstPullRequest
        self.listeningPorts = listeningPorts
        self.progress = progress
        self.statusEntries = statusEntries
        self.metadataBlocks = metadataBlocks
        self.logCount = logCount
        self.recentLogEntries = recentLogEntries
    }
}
