extension SidebarWorkspaceSnapshotBuilder.Snapshot {
    public struct ContextMenuImmediateFields: Equatable {
        let title: String
        let customDescription: String?
        let isPinned: Bool
        let customColorHex: String?
        let finderDirectoryPath: String?
    }

    public var contextMenuImmediateFields: ContextMenuImmediateFields {
        ContextMenuImmediateFields(
            title: title,
            customDescription: customDescription,
            isPinned: isPinned,
            customColorHex: customColorHex,
            finderDirectoryPath: finderDirectoryPath
        )
    }

    public func applyingContextMenuImmediateFields(from snapshot: SidebarWorkspaceSnapshotBuilder.Snapshot) -> Self {
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
            compactGitBranchSummaryText: compactGitBranchSummaryText,
            compactDirectoryCandidates: compactDirectoryCandidates,
            compactBranchDirectoryCandidates: compactBranchDirectoryCandidates,
            branchDirectoryLines: branchDirectoryLines,
            branchLinesContainBranch: branchLinesContainBranch,
            pullRequestRows: pullRequestRows,
            listeningPorts: listeningPorts,
            finderDirectoryPath: snapshot.finderDirectoryPath
        )
    }
}

// Context-menu actions should update stable row affordances immediately while
// keeping telemetry-heavy sidebar details frozen until the menu lifecycle ends.
public struct SidebarWorkspaceSnapshotRefreshPolicy {
    public struct Decision: Equatable {
        public let workspaceSnapshotStorage: SidebarWorkspaceSnapshotBuilder.Snapshot?
        public let pendingWorkspaceSnapshot: SidebarWorkspaceSnapshotBuilder.Snapshot?
        public let hasDeferredWorkspaceObservationInvalidation: Bool
    }

    public static func decision(
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

public struct SidebarWorkspaceRowInteractionState: Equatable {
    public private(set) var isPointerHovering = false
    public private(set) var contextMenuVisible = false
    private var contextMenuTrackingSuppressesCloseButton = false
    private var deferredPointerHoveringWhileContextMenuTracking: Bool?

    public init() {}

    public mutating func setPointerHovering(_ hovering: Bool) {
        if contextMenuTrackingSuppressesCloseButton {
            deferredPointerHoveringWhileContextMenuTracking = hovering
            isPointerHovering = false
            return
        }
        deferredPointerHoveringWhileContextMenuTracking = nil
        isPointerHovering = hovering
    }

    public mutating func contextMenuDidAppear() {
        contextMenuVisible = true
        contextMenuTrackingSuppressesCloseButton = true
        deferredPointerHoveringWhileContextMenuTracking = nil
        isPointerHovering = false
    }

    public mutating func contextMenuDidDisappear() {
        contextMenuVisible = false
        contextMenuTrackingSuppressesCloseButton = false
        applyDeferredPointerHovering()
    }

    public mutating func contextMenuTrackingDidBegin() {
        contextMenuTrackingSuppressesCloseButton = true
        deferredPointerHoveringWhileContextMenuTracking = nil
        isPointerHovering = false
    }

    public mutating func contextMenuTrackingDidEnd() {
        contextMenuTrackingSuppressesCloseButton = false
        applyDeferredPointerHovering()
    }

    public func shouldShowCloseButton(
        canCloseWorkspace: Bool,
        shortcutHintModeActive: Bool
    ) -> Bool {
        isPointerHovering
            && !contextMenuTrackingSuppressesCloseButton
            && canCloseWorkspace
            && !shortcutHintModeActive
    }

    private mutating func applyDeferredPointerHovering() {
        guard let deferredHover = deferredPointerHoveringWhileContextMenuTracking else { return }
        self.deferredPointerHoveringWhileContextMenuTracking = nil
        isPointerHovering = deferredHover
    }
}
