import CMUXAgentLaunch
import CmuxWorkspaces
import Foundation

/// App-target witness for the session autosave fingerprint.
///
/// The deterministic hashing lives in `CmuxWorkspaces.SessionFingerprintService`
/// over the `Sendable` `SessionWorkspaceFingerprintInput`. This conformance is
/// the irreducible live-state read seam: it walks the per-window `tabs`,
/// `workspaceGroups`, the app environment's notification store, and the
/// per-panel restorable-agent / surface-resume / text-box / hibernation state
/// that are all app-target-owned, flattening each into the package value types.
/// It reproduces the legacy `TabManager.sessionAutosaveFingerprint` read order
/// exactly so the resulting hash is byte-identical; the autosave skip
/// optimization depends on that stability.
extension TabManager: SessionFingerprintHosting {
    func makeSessionWorkspaceFingerprintInput(
        resolveRestorableAgent: (_ workspaceId: UUID, _ panelId: UUID)
            -> SessionFingerprintRestorableAgentSnapshot?,
        resolveSurfaceResumeBinding: (_ workspaceId: UUID, _ panelId: UUID)
            -> SessionFingerprintSurfaceResumeBindingSnapshot?
    ) -> SessionWorkspaceFingerprintInput {
        let notificationStore = appEnvironment?.notificationStore

        let groups = workspaceGroups.map { group in
            SessionFingerprintGroupSnapshot(
                id: group.id,
                name: group.name,
                isCollapsed: group.isCollapsed,
                isPinned: group.isPinned,
                anchorWorkspaceId: group.anchorWorkspaceId,
                customColor: group.customColor ?? "",
                iconSymbol: group.iconSymbol ?? ""
            )
        }

        let workspaces = tabs.prefix(SessionPersistencePolicy.maxWorkspacesPerWindow).map { workspace in
            let panelIds = workspace.panels.keys.sorted { $0.uuidString < $1.uuidString }
            let panels = panelIds.map { panelId -> SessionFingerprintPanelSnapshot in
                let terminalPanel = workspace.terminalPanel(for: panelId)
                return SessionFingerprintPanelSnapshot(
                    panelId: panelId,
                    isManualUnread: workspace.manualUnreadPanelIds.contains(panelId),
                    isRestoredUnread: workspace.restoredUnreadPanelIds.contains(panelId),
                    restoredUnreadContributesToWorkspace:
                        workspace.restoredUnreadIndicatorContributesToWorkspace(panelId: panelId),
                    hasVisibleNotificationIndicator:
                        notificationStore?.hasVisibleNotificationIndicator(
                            forTabId: workspace.id,
                            surfaceId: panelId
                        ) ?? false,
                    notifications: Self.fingerprintNotifications(
                        notificationStore?.notifications(forTabId: workspace.id, surfaceId: panelId) ?? []
                    ),
                    restorableAgent: resolveRestorableAgent(workspace.id, panelId),
                    agentHibernation: Self.fingerprintAgentHibernation(
                        (workspace.panels[panelId] as? TerminalPanel)?.agentHibernationState
                    ),
                    surfaceResumeBinding: resolveSurfaceResumeBinding(workspace.id, panelId),
                    hasTerminalPanel: terminalPanel != nil,
                    textBoxDraft: terminalPanel.flatMap {
                        Self.fingerprintTextBoxDraft($0.sessionTextBoxDraftSnapshot())
                    }
                )
            }

            let progress = workspace.progress.map {
                SessionFingerprintWorkspaceSnapshot.Progress(
                    quantizedValue: Int(($0.value * 1000).rounded()),
                    label: $0.label
                )
            }
            let gitBranch = workspace.gitBranch.map {
                SessionFingerprintWorkspaceSnapshot.GitBranch(branch: $0.branch, isDirty: $0.isDirty)
            }

            return SessionFingerprintWorkspaceSnapshot(
                id: workspace.id,
                groupId: workspace.groupId,
                focusedPanelId: workspace.focusedPanelId,
                currentDirectory: workspace.currentDirectory,
                customTitle: workspace.customTitle ?? "",
                customDescription: workspace.customDescription ?? "",
                customColor: workspace.customColor ?? "",
                isPinned: workspace.isPinned,
                panelsCount: workspace.panels.count,
                statusEntriesCount: workspace.statusEntries.count,
                metadataBlocksCount: workspace.metadataBlocks.count,
                logEntriesCount: workspace.logEntries.count,
                panelDirectoriesCount: workspace.panelDirectories.count,
                panelTitlesCount: workspace.panelTitles.count,
                panelPullRequestsCount: workspace.panelPullRequests.count,
                panelGitBranchesCount: workspace.panelGitBranches.count,
                surfaceListeningPortsCount: workspace.surfaceListeningPorts.count,
                hasManualUnread: notificationStore?.hasManualUnread(forTabId: workspace.id) ?? false,
                workspaceIsUnread: notificationStore?.workspaceIsUnread(forTabId: workspace.id) ?? false,
                notifications: Self.fingerprintNotifications(
                    notificationStore?.notifications(forTabId: workspace.id, surfaceId: nil) ?? []
                ),
                panels: panels,
                progress: progress,
                gitBranch: gitBranch
            )
        }

        return SessionWorkspaceFingerprintInput(
            selectedTabId: selectedTabId,
            workspaceCount: tabs.count,
            groups: groups,
            workspaces: workspaces
        )
    }

    // MARK: - App snapshot → package fingerprint snapshot flatteners

    /// Flattens an app `SessionRestorableAgentSnapshot` into the package value
    /// the fingerprint service hashes.
    nonisolated static func fingerprintRestorableAgent(
        _ snapshot: SessionRestorableAgentSnapshot?
    ) -> SessionFingerprintRestorableAgentSnapshot? {
        guard let snapshot else { return nil }
        return SessionFingerprintRestorableAgentSnapshot(
            kindRawValue: snapshot.kind.rawValue,
            sessionId: snapshot.sessionId,
            workingDirectory: snapshot.workingDirectory,
            launchCommand: fingerprintLaunchCommand(snapshot.launchCommand)
        )
    }

    nonisolated static func fingerprintLaunchCommand(
        _ launchCommand: AgentLaunchCommandSnapshot?
    ) -> SessionFingerprintAgentLaunchCommandSnapshot? {
        guard let launchCommand else { return nil }
        return SessionFingerprintAgentLaunchCommandSnapshot(
            launcher: launchCommand.launcher,
            executablePath: launchCommand.executablePath,
            arguments: launchCommand.arguments,
            workingDirectory: launchCommand.workingDirectory,
            environment: launchCommand.environment,
            capturedAt: launchCommand.capturedAt,
            source: launchCommand.source
        )
    }

    nonisolated static func fingerprintAgentHibernation(
        _ state: AgentHibernationPanelState?
    ) -> SessionFingerprintAgentHibernationSnapshot? {
        guard let state else { return nil }
        return SessionFingerprintAgentHibernationSnapshot(
            agent: fingerprintRestorableAgent(state.agent),
            hibernatedAt: state.hibernatedAt.timeIntervalSince1970,
            lastActivityAt: state.lastActivityAt.timeIntervalSince1970
        )
    }

    nonisolated static func fingerprintSurfaceResumeBinding(
        _ snapshot: SurfaceResumeBindingSnapshot?
    ) -> SessionFingerprintSurfaceResumeBindingSnapshot? {
        guard let snapshot else { return nil }
        return SessionFingerprintSurfaceResumeBindingSnapshot(
            name: snapshot.name,
            kind: snapshot.kind,
            command: snapshot.command,
            cwd: snapshot.cwd,
            checkpointId: snapshot.checkpointId,
            source: snapshot.source,
            environment: snapshot.environment,
            allowsAutomaticResume: snapshot.allowsAutomaticResume,
            isProcessDetected: snapshot.isProcessDetected,
            updatedAt: snapshot.updatedAt
        )
    }

    nonisolated static func fingerprintTextBoxDraft(
        _ snapshot: SessionTextBoxInputDraftSnapshot?
    ) -> SessionFingerprintTextBoxDraftSnapshot? {
        guard let snapshot else { return nil }
        return SessionFingerprintTextBoxDraftSnapshot(
            isActive: snapshot.isActive,
            parts: snapshot.parts.map { part in
                SessionFingerprintTextBoxDraftSnapshot.Part(
                    kindRawValue: part.kind.rawValue,
                    text: part.text,
                    attachment: part.attachment.map { attachment in
                        SessionFingerprintTextBoxDraftSnapshot.Attachment(
                            displayName: attachment.displayName,
                            submissionText: attachment.submissionText,
                            submissionPath: attachment.submissionPath,
                            localPath: attachment.localPath,
                            cleanupLocalPathWhenDisposed: attachment.cleanupLocalPathWhenDisposed
                        )
                    }
                )
            }
        )
    }

    nonisolated static func fingerprintNotifications(
        _ notifications: [TerminalNotification]
    ) -> [SessionFingerprintNotificationSnapshot] {
        notifications.map { notification in
            SessionFingerprintNotificationSnapshot(
                id: notification.id,
                title: notification.title,
                subtitle: notification.subtitle,
                body: notification.body,
                createdAt: notification.createdAt.timeIntervalSince1970,
                isRead: notification.isRead,
                paneFlash: notification.paneFlash,
                panelId: notification.panelId,
                clickAction: notification.clickAction.map { action in
                    switch action {
                    case .revealInFinder(let path):
                        return .revealInFinder(path: path)
                    }
                }
            )
        }
    }
}
