import AppKit
import CmuxFoundation

/// Builds bonsplit drop geometry only while an AppKit drag requests it.
/// Workspace reorder drops resolve their targets through the dedicated overlay
/// in `SidebarWorkspaceTableController` and never touch this.
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

    /// Converts visible table rows into Bonsplit targets while preserving the
    /// table's display order. Divider rows are visual-only and must not be
    /// offered to the workspace drop planner as UUID-bearing workspaces.
    static func makeBonsplitTargets(
        rows: [SidebarWorkspaceTableRowConfiguration],
        rowRange: Range<Int>,
        frameForRow: (Int) -> CGRect
    ) -> [SidebarDropPlanner.WorkspaceDropTarget] {
        rowRange.compactMap { row in
            let configuration = rows[row]
            guard !configuration.id.isDivider else { return nil }
            return SidebarDropPlanner.WorkspaceDropTarget(
                workspaceId: configuration.workspaceId,
                isPinned: configuration.isPinned,
                frame: frameForRow(row)
            )
        }
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
        bonsplitTargetBridge.updateTargets(
            Self.makeBonsplitTargets(rows: rows, rowRange: lower..<upper) { row in
                table.convert(table.rect(ofRow: row), to: container.bonsplitDropView)
            }
        )
        return true
    }

    private func clearTargets() {
        bonsplitTargetBridge.updateTargets([])
    }
}
