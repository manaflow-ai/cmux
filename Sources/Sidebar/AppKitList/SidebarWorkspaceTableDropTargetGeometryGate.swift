import AppKit
import CmuxFoundation

/// Builds sidebar drop geometry only while an AppKit drag requests it.
@MainActor
final class SidebarWorkspaceTableDropTargetGeometryGate {
    let bonsplitTargetBridge = SidebarBonsplitTabWorkspaceDropOverlay.TargetBridge()

    private weak var containerView: SidebarWorkspaceTableContainerView?
    private var isWorkspaceDragSessionActive = false
    private var isReorderTargetCollectionActive = false
    private var isBonsplitTargetCollectionActive = false

#if DEBUG
    var computationProbe: (() -> Void)?
#endif

    func attach(containerView: SidebarWorkspaceTableContainerView) {
        self.containerView = containerView
    }

    @discardableResult
    func setWorkspaceDragSessionActive(
        _ isActive: Bool,
        rows: [SidebarWorkspaceListRow]
    ) -> Bool {
        let wasActive = hasActiveDrag
        isWorkspaceDragSessionActive = isActive
        return handleActivityChange(wasActive: wasActive, rows: rows)
    }

    @discardableResult
    func setReorderTargetCollectionActive(
        _ isActive: Bool,
        rows: [SidebarWorkspaceListRow]
    ) -> Bool {
        let wasActive = hasActiveDrag
        isReorderTargetCollectionActive = isActive
        return handleActivityChange(wasActive: wasActive, rows: rows)
    }

    @discardableResult
    func setBonsplitTargetCollectionActive(
        _ isActive: Bool,
        rows: [SidebarWorkspaceListRow]
    ) -> Bool {
        let wasActive = hasActiveDrag
        isBonsplitTargetCollectionActive = isActive
        return handleActivityChange(wasActive: wasActive, rows: rows)
    }

    @discardableResult
    func refreshIfActive(rows: [SidebarWorkspaceListRow]) -> Bool {
        guard hasActiveDrag, let container = containerView else { return false }
#if DEBUG
        computationProbe?()
#endif
        let table = container.tableView
        let visibleRange = table.rows(in: table.visibleRect)
        guard visibleRange.location != NSNotFound, visibleRange.length > 0 else {
            clearTargets()
            return true
        }

        let lower = max(0, visibleRange.location)
        let upper = min(rows.count, visibleRange.location + visibleRange.length)
        let visibleIndexes = lower..<upper
        container.reorderDropView.targets = visibleIndexes.map { row in
            let listRow = rows[row]
            return SidebarWorkspaceReorderDropOverlay.Target(
                workspaceId: listRow.workspaceId,
                groupId: listRow.groupId,
                isGroupHeader: listRow.isGroupHeader,
                frame: table.convert(table.rect(ofRow: row), to: container.reorderDropView)
            )
        }
        container.reorderDropView.targetsDidUpdate()
        bonsplitTargetBridge.updateTargets(visibleIndexes.map { row in
            let listRow = rows[row]
            return SidebarDropPlanner.WorkspaceDropTarget(
                workspaceId: listRow.workspaceId,
                isPinned: listRow.isPinned,
                frame: table.convert(table.rect(ofRow: row), to: container.bonsplitDropView)
            )
        })
        return true
    }

    private var hasActiveDrag: Bool {
        isWorkspaceDragSessionActive
            || isReorderTargetCollectionActive
            || isBonsplitTargetCollectionActive
    }

    private func handleActivityChange(
        wasActive: Bool,
        rows: [SidebarWorkspaceListRow]
    ) -> Bool {
        guard wasActive != hasActiveDrag else { return false }
        if hasActiveDrag {
            return refreshIfActive(rows: rows)
        }
        clearTargets()
        return false
    }

    private func clearTargets() {
        guard let container = containerView else { return }
        container.reorderDropView.targets = []
        container.reorderDropView.targetsDidUpdate()
        bonsplitTargetBridge.updateTargets([])
    }
}
