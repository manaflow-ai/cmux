import AppKit
import CmuxFoundation
import CmuxWorkspaces
import SwiftUI

/// The intentionally inert visual row used for a persistent sidebar divider.
///
/// It has no selection or accessibility representation. The only action is
/// removal from its context menu; drag reordering is handled by the shared
/// sidebar drop planner using the divider's stable UUID.
struct SidebarDividerRowView: View, Equatable {
    let dividerId: UUID
    let onRemove: () -> Void
    let onDragStart: () -> NSItemProvider

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.dividerId == rhs.dividerId
    }

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.32))
            .frame(height: 1)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 10)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
            .onDrag {
                onDragStart()
            }
            .contextMenu {
                Button(
                    String(
                        localized: "sidebar.divider.remove",
                        defaultValue: "Remove Divider"
                    ),
                    role: .destructive,
                    action: onRemove
                )
            }
    }
}

extension VerticalTabsSidebar {
    /// Resolves a divider drag against the same row geometry used by the
    /// workspace drop overlay. Dividers may occupy only an interior gap
    /// between top-level rows; group members remain part of their group block.
    func sidebarDividerReorderDropPlan(
        point: CGPoint,
        targets: [SidebarWorkspaceReorderDropOverlay.Target],
        dividerId: UUID,
        renderContext: WorkspaceListRenderContext
    ) -> SidebarWorkspaceReorderDropPlan? {
        let dividerIds = Set(renderContext.sidebarDividers.map(\.id))
        let topLevelTargets = targets
            .filter { target in
                guard !dividerIds.contains(target.workspaceId) else { return false }
                return target.isGroupHeader || target.groupId == nil
            }
            .sorted { lhs, rhs in lhs.frame.minY < rhs.frame.minY }
        guard topLevelTargets.count > 1 else { return nil }

        let insertionIndex = topLevelTargets.firstIndex { point.y < $0.frame.midY }
            ?? topLevelTargets.count
        guard insertionIndex > 0, insertionIndex < topLevelTargets.count else {
            return nil
        }
        let afterWorkspaceId = topLevelTargets[insertionIndex - 1].workspaceId
        guard tabManager.workspaces.canMoveSidebarDivider(
            id: dividerId,
            after: afterWorkspaceId
        ) else {
            return nil
        }
        let target = topLevelTargets[insertionIndex]
        return SidebarWorkspaceReorderDropPlan(
            draggedWorkspaceId: dividerId,
            indicator: SidebarDropIndicator(tabId: target.workspaceId, edge: .top),
            indicatorScope: .raw,
            action: .moveDivider(afterWorkspaceId: afterWorkspaceId)
        )
    }

    /// Applies the divider plan through the model's single mutation path.
    @discardableResult
    func performSidebarDividerReorder(
        dividerId: UUID,
        afterWorkspaceId: UUID
    ) -> Bool {
        tabManager.workspaces.moveSidebarDivider(id: dividerId, after: afterWorkspaceId)
    }

    /// Builds a divider in the lazy SwiftUI sidebar path.
    @ViewBuilder
    func sidebarDividerRow(
        divider: WorkspaceSidebarDivider,
        shouldCollectWorkspaceDropTargets: Bool
    ) -> some View {
        SidebarDividerRowView(
            dividerId: divider.id,
            onRemove: { [weak tabManager] in
                _ = tabManager?.workspaces.removeSidebarDivider(id: divider.id)
            },
            onDragStart: { [weak tabManager] in
                guard let tabManager else {
                    return SidebarTabDragPayload(tabId: divider.id).provider()
                }
                dragState.beginDragging(tabId: divider.id)
                return SidebarTabDragPayload(tabId: divider.id).provider()
            }
        )
        .sidebarWorkspaceFrameAnchor(id: divider.id, isEnabled: shouldCollectWorkspaceDropTargets)
    }

    /// Builds the divider's hosted AppKit-table configuration. Keeping it a
    /// generic hosted row avoids adding divider-specific live state to the
    /// table controller or to the high-churn AppKit cells.
    @MainActor
    func sidebarDividerTableConfiguration(
        divider: WorkspaceSidebarDivider,
        renderContext: WorkspaceListRenderContext
    ) -> SidebarWorkspaceTableRowConfiguration {
        let row = SidebarDividerRowView(
            dividerId: divider.id,
            onRemove: { [weak tabManager] in
                _ = tabManager?.workspaces.removeSidebarDivider(id: divider.id)
            },
            // The NSTableView delegate starts the drag for table rows; this
            // closure remains for the SwiftUI-hosted prototype cell.
            onDragStart: { SidebarTabDragPayload(tabId: divider.id).provider() }
        )
        return SidebarWorkspaceTableRowConfiguration(
            id: .divider(divider.id),
            workspaceId: divider.id,
            groupId: nil,
            isGroupHeader: false,
            isPinned: false,
            environment: renderContext.environment,
            equivalenceValue: row,
            makeContent: { _, _ in AnyView(row) }
        )
    }
}
