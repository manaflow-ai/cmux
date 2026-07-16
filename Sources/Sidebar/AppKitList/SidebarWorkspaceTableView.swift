import SwiftUI

/// Container-level bridge mounting the AppKit-owned default workspace list once.
struct SidebarWorkspaceTableView: NSViewRepresentable {
    let rows: [SidebarWorkspaceTableRowConfiguration]
    let actions: SidebarWorkspaceTableActions
    let workspaceIds: [UUID]
    let selectedWorkspaceId: UUID?
    let selectedScrollTargetWorkspaceId: UUID?

#if DEBUG
    @Environment(\.sidebarLazyContractProbe) private var sidebarLazyContractProbe
#endif

    func makeCoordinator() -> SidebarWorkspaceTableController {
        SidebarWorkspaceTableController()
    }

    func makeNSView(context: Context) -> SidebarWorkspaceTableContainerView {
        context.coordinator.makeContainerView()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: SidebarWorkspaceTableContainerView,
        context: Context
    ) -> CGSize? {
        // The table is a viewport, never a content-sized view. The default
        // sizing falls back to the container's fitting size, which derives
        // from the table's full content height and inflates the ideal size —
        // at 128 workspaces the window itself grew to fit every row. Report
        // exactly the proposal; unspecified dimensions report zero so ideal
        // -size passes never see content-derived metrics.
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func updateNSView(_ nsView: SidebarWorkspaceTableContainerView, context: Context) {
#if DEBUG
        context.coordinator.reconfigurationProbe = sidebarLazyContractProbe.tableRootViewReconfigure
#endif
        context.coordinator.apply(
            rows: rows,
            actions: actions,
            workspaceIds: workspaceIds,
            selectedWorkspaceId: selectedWorkspaceId,
            selectedScrollTargetWorkspaceId: selectedScrollTargetWorkspaceId
        )
    }
}
