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
        let taskStatusHasOverride: Bool
        let taskStatusInferred: WorkspaceTaskStatus?
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
            taskStatusHasOverride: taskStatusHasOverride,
            taskStatusInferred: taskStatusInferred,
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
            // submenu, Mark as Done, checkbox clicks), so the glyph and
            // checklist must reflect the change immediately, not on menu close.
            taskStatus: snapshot.taskStatus,
            taskStatusHasOverride: snapshot.taskStatusHasOverride,
            taskStatusInferred: snapshot.taskStatusInferred,
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

struct SidebarWorkspaceRowInteractionState: Equatable {
    private(set) var isPointerHovering = false
    private(set) var contextMenuVisible = false
    private var contextMenuTrackingObserverInstalled = false
    private var deferredPointerHoveringWhileContextMenu: Bool?

    mutating func setPointerHovering(_ hovering: Bool) {
        if contextMenuVisible {
            if hovering || contextMenuTrackingObserverInstalled {
                deferredPointerHoveringWhileContextMenu = hovering
            }
            isPointerHovering = false
            return
        }
        if deferredPointerHoveringWhileContextMenu == nil, isPointerHovering == hovering {
            return
        }
        deferredPointerHoveringWhileContextMenu = nil
        isPointerHovering = hovering
    }

    mutating func contextMenuDidAppear() {
        deferredPointerHoveringWhileContextMenu = isPointerHovering
        contextMenuTrackingObserverInstalled = false
        contextMenuVisible = true
        isPointerHovering = false
    }

    mutating func contextMenuTrackingObserverDidInstall() {
        guard contextMenuVisible else { return }
        contextMenuTrackingObserverInstalled = true
    }

    mutating func contextMenuDidDisappear() {
        contextMenuVisible = false
        contextMenuTrackingObserverInstalled = false
        applyDeferredPointerHovering()
    }

    @discardableResult
    mutating func contextMenuTrackingDidEnd(pointerInsideRow: Bool) -> Bool {
        guard contextMenuVisible else { return false }
        deferredPointerHoveringWhileContextMenu = pointerInsideRow
        contextMenuVisible = false
        contextMenuTrackingObserverInstalled = false
        applyDeferredPointerHovering()
        return true
    }

    func shouldShowCloseButton(
        canCloseWorkspace: Bool,
        shortcutHintModeActive: Bool
    ) -> Bool {
        isPointerHovering
            && !contextMenuVisible
            && canCloseWorkspace
            && !shortcutHintModeActive
    }

    private mutating func applyDeferredPointerHovering() {
        guard let deferredHover = deferredPointerHoveringWhileContextMenu else { return }
        self.deferredPointerHoveringWhileContextMenu = nil
        isPointerHovering = deferredHover
    }
}
