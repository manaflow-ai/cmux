import AppKit
import CmuxFoundation

/// Builds bonsplit drop geometry only while an AppKit drag requests it.
/// Workspace reorder drops resolve their targets synchronously per
/// `validateDrop` in `SidebarWorkspaceTableController` and never touch this.
@MainActor
final class SidebarWorkspaceTableDropTargetGeometryGate {
    let bonsplitTargetBridge = SidebarBonsplitTabWorkspaceDropOverlay.TargetBridge()

    private weak var containerView: SidebarWorkspaceTableContainerView?
    private var isBonsplitTargetCollectionActive = false

#if DEBUG
    var computationProbe: (() -> Void)?
#endif

    func attach(containerView: SidebarWorkspaceTableContainerView) {
        self.containerView = containerView
    }

    @discardableResult
    func setBonsplitTargetCollectionActive(
        _ isActive: Bool,
        rows: [SidebarWorkspaceTableRowConfiguration]
    ) -> Bool {
        guard isBonsplitTargetCollectionActive != isActive else { return false }
        isBonsplitTargetCollectionActive = isActive
        if isActive {
            return refreshIfActive(rows: rows)
        }
        clearTargets()
        return false
    }

    @discardableResult
    func refreshIfActive(rows: [SidebarWorkspaceTableRowConfiguration]) -> Bool {
        guard isBonsplitTargetCollectionActive, let container = containerView else { return false }
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
        bonsplitTargetBridge.updateTargets((lower..<upper).map { row in
            let configuration = rows[row]
            return SidebarDropPlanner.WorkspaceDropTarget(
                workspaceId: configuration.workspaceId,
                isPinned: configuration.isPinned,
                frame: table.convert(table.rect(ofRow: row), to: container.bonsplitDropView)
            )
        })
        return true
    }

    private func clearTargets() {
        bonsplitTargetBridge.updateTargets([])
    }
}
