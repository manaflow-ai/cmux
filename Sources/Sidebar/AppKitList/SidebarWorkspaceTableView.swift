import CmuxNotifications
import SwiftUI

/// Container-level bridge mounting the AppKit-owned default workspace list once.
struct SidebarWorkspaceTableView: NSViewRepresentable {
    let rows: [SidebarWorkspaceTableRowConfiguration]
    let actions: SidebarWorkspaceTableActions
    let workspaceIds: [UUID]
    let selectedWorkspaceId: UUID?
    let selectedScrollTargetWorkspaceId: UUID?
    let isPresented: Bool
    let unreadSource: SidebarUnreadModel
    /// Invoked when a completed row click parks awaiting live actions; the
    /// owner must invalidate itself so this view re-applies (issue #9690).
    let onDeferredClickAwaitingApply: () -> Void

#if DEBUG
    @Environment(\.sidebarLazyContractProbe) private var sidebarLazyContractProbe
#endif

    func makeCoordinator() -> SidebarWorkspaceTableController {
        SidebarWorkspaceTableController()
    }

    func makeNSView(context: Context) -> SidebarWorkspaceTableContainerView {
        context.coordinator.makeContainerView()
    }

    func updateNSView(_ nsView: SidebarWorkspaceTableContainerView, context: Context) {
#if DEBUG
        context.coordinator.reconfigurationProbe = sidebarLazyContractProbe.tableRootViewReconfigure
#endif
        context.coordinator.setUnreadSource(unreadSource)
        context.coordinator.onDeferredRowClickAwaitingApply = onDeferredClickAwaitingApply
        context.coordinator.setPresentationActive(isPresented, workspaceIds: workspaceIds)
        guard isPresented else { return }
        context.coordinator.apply(
            rows: rows,
            actions: actions,
            workspaceIds: workspaceIds,
            selectedWorkspaceId: selectedWorkspaceId,
            selectedScrollTargetWorkspaceId: selectedScrollTargetWorkspaceId
        )
    }

    static func dismantleNSView(
        _ nsView: SidebarWorkspaceTableContainerView,
        coordinator: SidebarWorkspaceTableController
    ) {
        coordinator.dismantleContainerView(nsView)
    }
}
