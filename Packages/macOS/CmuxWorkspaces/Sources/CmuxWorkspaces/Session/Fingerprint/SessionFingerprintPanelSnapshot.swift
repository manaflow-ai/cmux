public import Foundation

/// The per-panel values the session autosave fingerprint folds into its hash,
/// one per sorted panel id within a workspace.
///
/// Carries exactly what the legacy per-`panelId` loop in
/// `TabManager.sessionAutosaveFingerprint` combined, in order, so
/// ``SessionFingerprintService`` reproduces the hash byte-identically. The
/// app-side ``SessionFingerprintHosting`` witness builds these from the live
/// workspace/panel/notification-store state.
public struct SessionFingerprintPanelSnapshot: Sendable, Equatable {
    /// The panel id (legacy sorted `workspace.panels.keys`).
    public let panelId: UUID
    /// Legacy `workspace.panelDirectories[panelId] ?? ""`.
    public let directory: String
    /// Legacy `workspace.remoteDirectoryReportPanelIds.contains(panelId)`.
    public let hasRemoteDirectoryReport: Bool
    /// Legacy `workspace.remoteDirectoryTrustRequiredPanelIds.contains(panelId)`.
    public let requiresRemoteDirectoryTrust: Bool
    /// Legacy `workspace.manualUnreadPanelIds.contains(panelId)`.
    public let isManualUnread: Bool
    /// Legacy `workspace.restoredUnreadPanelIds.contains(panelId)`.
    public let isRestoredUnread: Bool
    /// Legacy `workspace.restoredUnreadIndicatorContributesToWorkspace(panelId:)`,
    /// an `Optional<Bool>` folded directly (the legacy combine never coalesced).
    public let restoredUnreadContributesToWorkspace: Bool?
    /// Legacy `notificationStore?.hasVisibleNotificationIndicator(forTabId:surfaceId:) ?? false`.
    public let hasVisibleNotificationIndicator: Bool
    /// Legacy panel-scoped `notificationStore?.notifications(forTabId:surfaceId:)`,
    /// flattened (service sorts and folds them).
    public let notifications: [SessionFingerprintNotificationSnapshot]
    /// Legacy `restorableAgentIndex.snapshot(workspaceId:panelId:)`, flattened.
    public let restorableAgent: SessionFingerprintRestorableAgentSnapshot?
    /// Legacy `(panel as? TerminalPanel)?.agentHibernationState`, flattened.
    public let agentHibernation: SessionFingerprintAgentHibernationSnapshot?
    /// Legacy `workspace.effectiveSurfaceResumeBinding(panelId:surfaceResumeBindingIndex:)`,
    /// flattened.
    public let surfaceResumeBinding: SessionFingerprintSurfaceResumeBindingSnapshot?
    /// Whether the panel is a terminal panel (legacy `workspace.terminalPanel(for:)`).
    /// When false the fingerprint folds in a bare `false` for the draft slot.
    public let hasTerminalPanel: Bool
    /// Legacy `terminalPanel.sessionTextBoxDraftSnapshot()`, flattened. Only
    /// folded when ``hasTerminalPanel`` is true.
    public let textBoxDraft: SessionFingerprintTextBoxDraftSnapshot?

    /// Creates a flattened per-panel fingerprint input.
    public init(
        panelId: UUID,
        directory: String,
        hasRemoteDirectoryReport: Bool,
        requiresRemoteDirectoryTrust: Bool,
        isManualUnread: Bool,
        isRestoredUnread: Bool,
        restoredUnreadContributesToWorkspace: Bool?,
        hasVisibleNotificationIndicator: Bool,
        notifications: [SessionFingerprintNotificationSnapshot],
        restorableAgent: SessionFingerprintRestorableAgentSnapshot?,
        agentHibernation: SessionFingerprintAgentHibernationSnapshot?,
        surfaceResumeBinding: SessionFingerprintSurfaceResumeBindingSnapshot?,
        hasTerminalPanel: Bool,
        textBoxDraft: SessionFingerprintTextBoxDraftSnapshot?
    ) {
        self.panelId = panelId
        self.directory = directory
        self.hasRemoteDirectoryReport = hasRemoteDirectoryReport
        self.requiresRemoteDirectoryTrust = requiresRemoteDirectoryTrust
        self.isManualUnread = isManualUnread
        self.isRestoredUnread = isRestoredUnread
        self.restoredUnreadContributesToWorkspace = restoredUnreadContributesToWorkspace
        self.hasVisibleNotificationIndicator = hasVisibleNotificationIndicator
        self.notifications = notifications
        self.restorableAgent = restorableAgent
        self.agentHibernation = agentHibernation
        self.surfaceResumeBinding = surfaceResumeBinding
        self.hasTerminalPanel = hasTerminalPanel
        self.textBoxDraft = textBoxDraft
    }
}
