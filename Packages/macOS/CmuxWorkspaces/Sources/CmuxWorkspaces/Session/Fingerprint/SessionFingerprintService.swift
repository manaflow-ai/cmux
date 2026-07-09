public import Foundation

/// Computes the session autosave fingerprint over a flattened, `Sendable`
/// ``SessionWorkspaceFingerprintInput``.
///
/// This is the deterministic hashing half of the session-autosave skip
/// optimization, lifted out of `TabManager.sessionAutosaveFingerprint` and its
/// `nonisolated static hash*` helper family. The legacy code reached into ~25
/// live god fields plus `AppDelegate.shared.notificationStore`; that reach now
/// lives entirely in the app-side ``SessionFingerprintHosting`` witness, which
/// flattens the live state into the input. The service folds the input into a
/// `Hasher` in the exact legacy order so the result is byte-identical: the
/// autosave timer compares the previous and current fingerprint and skips the
/// write when they match, so any reordering would silently change skip behavior.
///
/// Isolation: a stateless `Sendable` struct, not an actor and not a static-only
/// namespace. The methods are pure transforms over the value-typed input with no
/// mutable state to protect; the app holds one shared instance and forwards.
public struct SessionFingerprintService: Sendable {
    /// Creates a fingerprint service.
    public init() {}

    /// Computes the full session autosave fingerprint for a window's flattened
    /// state. Byte-identical to the legacy `TabManager.sessionAutosaveFingerprint`.
    public func fingerprint(for input: SessionWorkspaceFingerprintInput) -> Int {
        var hasher = Hasher()
        hasher.combine(input.selectedTabId)
        hasher.combine(input.workspaceCount)

        // Workspace groups participate in the session snapshot, so changes that
        // only touch group metadata (rename / collapse / pin a group, or move a
        // workspace between groups without reordering tabs) must bump the
        // fingerprint or the autosave timer skips the write.
        hasher.combine(input.groups.count)
        for group in input.groups {
            hasher.combine(group.id)
            hasher.combine(group.name)
            hasher.combine(group.isCollapsed)
            hasher.combine(group.isPinned)
            hasher.combine(group.anchorWorkspaceId)
            hasher.combine(group.customColor)
            hasher.combine(group.iconSymbol)
        }

        for workspace in input.workspaces {
            hasher.combine(workspace.id)
            hasher.combine(workspace.groupId)
            hasher.combine(workspace.focusedPanelId)
            hasher.combine(workspace.currentDirectory)
            hasher.combine(workspace.customTitle)
            hasher.combine(workspace.customDescription)
            hasher.combine(workspace.customColor)
            hasher.combine(workspace.isPinned)
            hasher.combine(workspace.panelsCount)
            hasher.combine(workspace.statusEntriesCount)
            hasher.combine(workspace.metadataBlocksCount)
            hasher.combine(workspace.logEntriesCount)
            hasher.combine(workspace.panelDirectoriesCount)
            hasher.combine(workspace.panelTitlesCount)
            hasher.combine(workspace.panelPullRequestsCount)
            hasher.combine(workspace.panelGitBranchesCount)
            hasher.combine(workspace.surfaceListeningPortsCount)
            hasher.combine(workspace.hasManualUnread)
            hasher.combine(workspace.workspaceIsUnread)
            hashNotifications(workspace.notifications, into: &hasher)

            hasher.combine(workspace.panels.count)
            for panel in workspace.panels {
                hasher.combine(panel.panelId)
                hasher.combine(panel.directory)
                hasher.combine(panel.hasRemoteDirectoryReport)
                hasher.combine(panel.requiresRemoteDirectoryTrust)
                hasher.combine(panel.isManualUnread)
                hasher.combine(panel.isRestoredUnread)
                hasher.combine(panel.restoredUnreadContributesToWorkspace)
                hasher.combine(panel.hasVisibleNotificationIndicator)
                hashNotifications(panel.notifications, into: &hasher)
                hashRestorableAgentSnapshot(panel.restorableAgent, into: &hasher)
                hashAgentHibernationSnapshot(panel.agentHibernation, into: &hasher)
                hashSurfaceResumeBindingSnapshot(panel.surfaceResumeBinding, into: &hasher)
                if panel.hasTerminalPanel {
                    hashTextBoxDraftSnapshot(panel.textBoxDraft, into: &hasher)
                } else {
                    hasher.combine(false)
                }
            }

            if let progress = workspace.progress {
                hasher.combine(progress.quantizedValue)
                hasher.combine(progress.label)
            } else {
                hasher.combine(-1)
            }

            if let gitBranch = workspace.gitBranch {
                hasher.combine(gitBranch.branch)
                hasher.combine(gitBranch.isDirty)
            } else {
                hasher.combine("")
                hasher.combine(false)
            }
        }

        return hasher.finalize()
    }

    /// Computes the standalone fingerprint of one restorable-agent snapshot,
    /// used to detect resume-relevant changes. Byte-identical to the legacy
    /// `TabManager.restorableAgentSnapshotFingerprint(_:)`.
    public func restorableAgentFingerprint(
        for snapshot: SessionFingerprintRestorableAgentSnapshot?
    ) -> Int {
        var hasher = Hasher()
        hashRestorableAgentSnapshot(snapshot, into: &hasher)
        return hasher.finalize()
    }

    // MARK: - Hash helpers (lifted verbatim from TabManager, receiver moved)

    private func hashRestorableAgentSnapshot(
        _ snapshot: SessionFingerprintRestorableAgentSnapshot?,
        into hasher: inout Hasher
    ) {
        guard let snapshot else {
            hasher.combine(false)
            return
        }

        hasher.combine(true)
        hasher.combine(snapshot.kindRawValue)
        hasher.combine(snapshot.sessionId)
        hashOptionalString(snapshot.workingDirectory, into: &hasher)
        hashAgentLaunchCommand(snapshot.launchCommand, into: &hasher)
    }

    private func hashAgentLaunchCommand(
        _ launchCommand: SessionFingerprintAgentLaunchCommandSnapshot?,
        into hasher: inout Hasher
    ) {
        guard let launchCommand else {
            hasher.combine(false)
            return
        }

        hasher.combine(true)
        hashOptionalString(launchCommand.launcher, into: &hasher)
        hashOptionalString(launchCommand.executablePath, into: &hasher)
        hasher.combine(launchCommand.arguments)
        hashOptionalString(launchCommand.workingDirectory, into: &hasher)
        if let environment = launchCommand.environment {
            hasher.combine(true)
            hasher.combine(environment.count)
            for key in environment.keys.sorted() {
                hasher.combine(key)
                hasher.combine(environment[key])
            }
        } else {
            hasher.combine(false)
        }
        hashOptionalDouble(launchCommand.capturedAt, into: &hasher)
        hashOptionalString(launchCommand.source, into: &hasher)
    }

    private func hashAgentHibernationSnapshot(
        _ state: SessionFingerprintAgentHibernationSnapshot?,
        into hasher: inout Hasher
    ) {
        guard let state else {
            hasher.combine(false)
            return
        }

        hasher.combine(true)
        hashRestorableAgentSnapshot(state.agent, into: &hasher)
        hasher.combine(state.hibernatedAt)
        hasher.combine(state.lastActivityAt)
    }

    private func hashSurfaceResumeBindingSnapshot(
        _ snapshot: SessionFingerprintSurfaceResumeBindingSnapshot?,
        into hasher: inout Hasher
    ) {
        guard let snapshot else {
            hasher.combine(false)
            return
        }

        hasher.combine(true)
        hashOptionalString(snapshot.name, into: &hasher)
        hashOptionalString(snapshot.kind, into: &hasher)
        hasher.combine(snapshot.command)
        hashOptionalString(snapshot.cwd, into: &hasher)
        hashOptionalString(snapshot.checkpointId, into: &hasher)
        hashOptionalString(snapshot.source, into: &hasher)
        hashStringMap(snapshot.environment, into: &hasher)
        hasher.combine(snapshot.allowsAutomaticResume)
        if snapshot.isProcessDetected {
            hasher.combine(false)
        } else {
            hashOptionalDouble(snapshot.updatedAt, into: &hasher)
        }
    }

    private func hashTextBoxDraftSnapshot(
        _ snapshot: SessionFingerprintTextBoxDraftSnapshot?,
        into hasher: inout Hasher
    ) {
        guard let snapshot else {
            hasher.combine(false)
            return
        }

        hasher.combine(true)
        hasher.combine(snapshot.isActive)
        hasher.combine(snapshot.parts.count)
        for part in snapshot.parts {
            hasher.combine(part.kindRawValue)
            hashOptionalString(part.text, into: &hasher)
            hashTextBoxAttachmentSnapshot(part.attachment, into: &hasher)
        }
    }

    private func hashTextBoxAttachmentSnapshot(
        _ snapshot: SessionFingerprintTextBoxDraftSnapshot.Attachment?,
        into hasher: inout Hasher
    ) {
        guard let snapshot else {
            hasher.combine(false)
            return
        }

        hasher.combine(true)
        hasher.combine(snapshot.displayName)
        hasher.combine(snapshot.submissionText)
        hasher.combine(snapshot.submissionPath)
        hashOptionalString(snapshot.localPath, into: &hasher)
        hasher.combine(snapshot.cleanupLocalPathWhenDisposed)
    }

    private func hashNotifications(
        _ notifications: [SessionFingerprintNotificationSnapshot],
        into hasher: inout Hasher
    ) {
        hasher.combine(notifications.count)
        for notification in notifications.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            hasher.combine(notification.id)
            hasher.combine(notification.title)
            hasher.combine(notification.subtitle)
            hasher.combine(notification.body)
            hasher.combine(notification.createdAt)
            hasher.combine(notification.isRead)
            hasher.combine(notification.paneFlash)
            hasher.combine(notification.panelId)
            hasher.combine(notification.clickAction)
        }
    }

    private func hashOptionalString(_ value: String?, into hasher: inout Hasher) {
        if let value {
            hasher.combine(true)
            hasher.combine(value)
        } else {
            hasher.combine(false)
        }
    }

    private func hashOptionalDouble(_ value: Double?, into hasher: inout Hasher) {
        if let value {
            hasher.combine(true)
            hasher.combine(value)
        } else {
            hasher.combine(false)
        }
    }

    private func hashStringMap(_ value: [String: String]?, into hasher: inout Hasher) {
        guard let value, !value.isEmpty else {
            hasher.combine(false)
            return
        }
        hasher.combine(true)
        let keys = value.keys.sorted()
        hasher.combine(keys.count)
        for key in keys {
            hasher.combine(key)
            hasher.combine(value[key] ?? "")
        }
    }
}
