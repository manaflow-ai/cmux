import CmuxWorkspaces

extension SidebarWorkspaceSnapshotBuilder.Snapshot {
    struct ContextMenuImmediateFields: Equatable {
        let title: String
        let customDescription: String?
        let isPinned: Bool
        let customColorHex: String?
        let finderDirectoryPath: String?
        let mediaActivity: BrowserMediaActivity
        let taskStatus: WorkspaceTaskStatus?
        let todoStatusMenuModel: SidebarWorkspaceCompactStatusMenuModel?
        let hasManualTaskStatus: Bool
        let checklistItems: [WorkspaceChecklistItem]
        let checklistCompletedCount: Int
        let checklistTotalCount: Int
        let checklistFirstUncheckedText: String?
        let activeCodingAgentCount: Int
    }

    var contextMenuImmediateFields: ContextMenuImmediateFields {
        ContextMenuImmediateFields(
            title: title,
            customDescription: customDescription,
            isPinned: isPinned,
            customColorHex: customColorHex,
            finderDirectoryPath: finderDirectoryPath,
            mediaActivity: mediaActivity,
            taskStatus: taskStatus,
            todoStatusMenuModel: todoStatusMenuModel,
            hasManualTaskStatus: hasManualTaskStatus,
            checklistItems: checklistItems,
            checklistCompletedCount: checklistCompletedCount,
            checklistTotalCount: checklistTotalCount,
            checklistFirstUncheckedText: checklistFirstUncheckedText,
            activeCodingAgentCount: activeCodingAgentCount
        )
    }

    func applyingContextMenuImmediateFields(from snapshot: SidebarWorkspaceSnapshotBuilder.Snapshot) -> Self {
        guard contextMenuImmediateFields != snapshot.contextMenuImmediateFields else { return self }
        return Self(
            presentationKey: snapshot.presentationKey,
            title: snapshot.title,
            customDescription: snapshot.customDescription,
            isPinned: snapshot.isPinned,
            customColorHex: snapshot.customColorHex,
            remoteWorkspaceSidebarText: remoteWorkspaceSidebarText,
            remoteConnectionStatusText: remoteConnectionStatusText,
            remoteStateHelpText: remoteStateHelpText,
            showsRemoteReconnectAffordance: showsRemoteReconnectAffordance,
            copyableSidebarSSHError: copyableSidebarSSHError,
            latestConversationMessage: latestConversationMessage,
            metadataEntries: metadataEntries,
            metadataBlocks: metadataBlocks,
            latestLog: latestLog,
            progress: progress,
            // The loading spinner is a leading row glyph like mediaActivity, so
            // it also updates immediately while the context menu is open.
            activeCodingAgentCount: snapshot.activeCodingAgentCount,
            compactGitBranchSummaryText: compactGitBranchSummaryText,
            compactDirectoryCandidates: compactDirectoryCandidates,
            compactBranchDirectoryCandidates: compactBranchDirectoryCandidates,
            branchDirectoryLines: branchDirectoryLines,
            branchLinesContainBranch: branchLinesContainBranch,
            pullRequestRows: pullRequestRows,
            listeningPorts: listeningPorts,
            finderDirectoryPath: snapshot.finderDirectoryPath,
            // Media activity drives a leading row glyph, so stale values are
            // visually worse than ordinary telemetry text while the menu is open.
            mediaActivity: snapshot.mediaActivity,
            // Todo status/checklist are mutated FROM this context menu (Status
            // submenu, Mark as Done, checkbox clicks), so the done-row dim and
            // checklist must reflect the change immediately, not on menu close.
            taskStatus: snapshot.taskStatus,
            todoStatusMenuModel: snapshot.todoStatusMenuModel,
            hasManualTaskStatus: snapshot.hasManualTaskStatus,
            checklistItems: snapshot.checklistItems,
            checklistCompletedCount: snapshot.checklistCompletedCount,
            checklistTotalCount: snapshot.checklistTotalCount,
            checklistFirstUncheckedText: snapshot.checklistFirstUncheckedText
        )
    }
}

// Context-menu actions should update stable row affordances immediately while
// keeping telemetry-heavy sidebar details frozen until the menu lifecycle ends.
struct SidebarWorkspaceSnapshotRefreshPolicy {
    struct Decision: Equatable {
        let workspaceSnapshotStorage: SidebarWorkspaceSnapshotBuilder.Snapshot?
        let pendingWorkspaceSnapshot: SidebarWorkspaceSnapshotBuilder.Snapshot?
        let hasDeferredWorkspaceObservationInvalidation: Bool
    }

    func decision(
        current: SidebarWorkspaceSnapshotBuilder.Snapshot?,
        next: SidebarWorkspaceSnapshotBuilder.Snapshot,
        force: Bool,
        contextMenuVisible: Bool
    ) -> Decision {
        guard contextMenuVisible else {
            return Decision(
                workspaceSnapshotStorage: force || current != next ? next : current,
                pendingWorkspaceSnapshot: nil,
                hasDeferredWorkspaceObservationInvalidation: false
            )
        }

        let displayedBaseline = current ?? next
        let displayedSnapshot = displayedBaseline.applyingContextMenuImmediateFields(from: next)
        let hasDeferredChanges = force || displayedSnapshot != next

        return Decision(
            workspaceSnapshotStorage: displayedSnapshot,
            pendingWorkspaceSnapshot: hasDeferredChanges ? next : nil,
            hasDeferredWorkspaceObservationInvalidation: hasDeferredChanges
        )
    }
}
