import Foundation
import Observation
import CmuxSidebar

/// Owns the mutable state and refresh machinery for the default workspace sidebar.
///
/// Keeping this state behind one reference prevents SwiftUI view-builder closures
/// from copying the much larger ``VerticalTabsSidebar`` value graph.
@MainActor
@Observable
final class DefaultWorkspaceSidebarOwner {
    var isBonsplitWorkspaceDropTargetCollectionActive = false
    var isWorkspaceReorderDropTargetCollectionActive = false
    var frozenShortcutHintsTabId: UUID?
    var frozenShortcutHintsValue = false
    var pendingSelectedWorkspaceScrollId: UUID?
    var expandedChecklistWorkspaceIds: Set<UUID> = []
    var expandedMetadataWorkspaceIds: Set<UUID> = []
    var expandedMarkdownWorkspaceIds: Set<UUID> = []
    var checklistAddFieldActivationTokens: [UUID: Int] = [:]
    var editingChecklistItemIds: [UUID: UUID] = [:]
    var appKitPostResizeRefreshToken: UInt64 = 0
    var checklistPopoverWorkspaceId: UUID?
    var workspaceSnapshotsById: [UUID: SidebarWorkspaceSnapshotBuilder.Snapshot] = [:]
    var anchorCwdRevision = 0

    @ObservationIgnored
    let bonsplitWorkspaceDropTargetBridge = SidebarBonsplitTabWorkspaceDropOverlay.TargetBridge()
    @ObservationIgnored
    let workspaceReorderDropTargetBridge = SidebarWorkspaceReorderDropOverlay.TargetBridge()
    @ObservationIgnored
    let appKitRowSnapshotCache = SidebarRowSnapshotCache()
    @ObservationIgnored
    let appKitFrozenTableRowsBox = SidebarAppKitFrozenRowsBox()
    @ObservationIgnored
    let workspaceSnapshotRefreshCoalescer = SidebarWorkspaceSnapshotRefreshCoalescer()

    func scheduleWorkspaceSnapshotRefresh(
        workspaceId: UUID,
        flush: @MainActor @escaping (Set<UUID>) -> Void
    ) {
        workspaceSnapshotRefreshCoalescer.schedule(
            workspaceId: workspaceId,
            flush: flush
        )
    }

    func resetPresentationState() {
        appKitFrozenTableRowsBox.rows = nil
        appKitRowSnapshotCache.prune(keeping: [])
        workspaceSnapshotRefreshCoalescer.cancel()
        workspaceSnapshotsById = [:]
        isBonsplitWorkspaceDropTargetCollectionActive = false
        isWorkspaceReorderDropTargetCollectionActive = false
        frozenShortcutHintsTabId = nil
        frozenShortcutHintsValue = false
        pendingSelectedWorkspaceScrollId = nil
        checklistPopoverWorkspaceId = nil
    }
}
