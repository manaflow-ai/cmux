extension SidebarWorkspaceSnapshotBuilder.Snapshot {
    struct ContextMenuImmediateFields: Equatable {
        let title: String
        let customDescription: String?
        let isPinned: Bool
        let customColorHex: String?
    }

    var contextMenuImmediateFields: ContextMenuImmediateFields {
        ContextMenuImmediateFields(
            title: title,
            customDescription: customDescription,
            isPinned: isPinned,
            customColorHex: customColorHex
        )
    }

    func applyingContextMenuImmediateFields(from snapshot: SidebarWorkspaceSnapshotBuilder.Snapshot) -> Self {
        guard contextMenuImmediateFields != snapshot.contextMenuImmediateFields else { return self }
        return Self(
            title: snapshot.title,
            customDescription: snapshot.customDescription,
            isPinned: snapshot.isPinned,
            customColorHex: snapshot.customColorHex,
            remoteWorkspaceSidebarText: remoteWorkspaceSidebarText,
            remoteConnectionStatusText: remoteConnectionStatusText,
            remoteStateHelpText: remoteStateHelpText,
            copyableSidebarSSHError: copyableSidebarSSHError,
            latestSubmittedMessage: latestSubmittedMessage,
            latestSubmittedAt: latestSubmittedAt,
            metadataEntries: metadataEntries,
            metadataBlocks: metadataBlocks,
            latestLog: latestLog,
            progress: progress,
            compactGitBranchSummaryText: compactGitBranchSummaryText,
            compactBranchDirectoryRow: compactBranchDirectoryRow,
            branchDirectoryLines: branchDirectoryLines,
            branchLinesContainBranch: branchLinesContainBranch,
            pullRequestRows: pullRequestRows,
            listeningPorts: listeningPorts
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

    static func decision(
        current: SidebarWorkspaceSnapshotBuilder.Snapshot?,
        next: SidebarWorkspaceSnapshotBuilder.Snapshot,
        force: Bool,
        freezesSidebarWorkspaceDetails: Bool
    ) -> Decision {
        guard freezesSidebarWorkspaceDetails else {
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
    // AppKit menu tracking is the authoritative freeze lifetime for row pointer
    // context menus. SwiftUI appearance is only a fallback for menu surfaces that
    // do not emit AppKit tracking; it must not end an active AppKit-tracking
    // freeze early.
    private enum ContextMenuDetailsFreezePhase: Equatable {
        case live
        case swiftUIFallback
        case appKitTracking
    }

    private(set) var isPointerHovering = false
    private var contextMenuDetailsFreezePhase: ContextMenuDetailsFreezePhase = .live
    private var contextMenuTrackingSuppressesCloseButton = false
    private var deferredPointerHoveringWhileContextMenuTracking: Bool?

    var freezesSidebarWorkspaceDetails: Bool {
        contextMenuDetailsFreezePhase != .live
    }

    mutating func setPointerHovering(_ hovering: Bool) {
        if contextMenuTrackingSuppressesCloseButton {
            deferredPointerHoveringWhileContextMenuTracking = hovering
            isPointerHovering = false
            return
        }
        deferredPointerHoveringWhileContextMenuTracking = nil
        isPointerHovering = hovering
    }

    mutating func contextMenuDidAppear() {
        beginSwiftUIFallbackContextMenuFreeze()
        contextMenuTrackingSuppressesCloseButton = true
        deferredPointerHoveringWhileContextMenuTracking = nil
        isPointerHovering = false
    }

    mutating func contextMenuDidDisappear() {
        endSwiftUIFallbackContextMenuFreeze()
        contextMenuTrackingSuppressesCloseButton = false
        applyDeferredPointerHovering()
    }

    mutating func contextMenuTrackingDidBegin() {
        beginAppKitTrackingContextMenuFreeze()
        contextMenuTrackingSuppressesCloseButton = true
        deferredPointerHoveringWhileContextMenuTracking = nil
        isPointerHovering = false
    }

    mutating func contextMenuTrackingDidEnd() {
        endAppKitTrackingContextMenuFreeze()
        contextMenuTrackingSuppressesCloseButton = false
        applyDeferredPointerHovering()
    }

    func shouldShowCloseButton(
        canCloseWorkspace: Bool,
        shortcutHintModeActive: Bool
    ) -> Bool {
        isPointerHovering
            && !contextMenuTrackingSuppressesCloseButton
            && canCloseWorkspace
            && !shortcutHintModeActive
    }

    private mutating func beginSwiftUIFallbackContextMenuFreeze() {
        guard contextMenuDetailsFreezePhase == .live else { return }
        contextMenuDetailsFreezePhase = .swiftUIFallback
    }

    private mutating func endSwiftUIFallbackContextMenuFreeze() {
        guard contextMenuDetailsFreezePhase == .swiftUIFallback else { return }
        contextMenuDetailsFreezePhase = .live
    }

    private mutating func beginAppKitTrackingContextMenuFreeze() {
        contextMenuDetailsFreezePhase = .appKitTracking
    }

    private mutating func endAppKitTrackingContextMenuFreeze() {
        contextMenuDetailsFreezePhase = .live
    }

    private mutating func applyDeferredPointerHovering() {
        guard let deferredHover = deferredPointerHoveringWhileContextMenuTracking else { return }
        self.deferredPointerHoveringWhileContextMenuTracking = nil
        isPointerHovering = deferredHover
    }
}
