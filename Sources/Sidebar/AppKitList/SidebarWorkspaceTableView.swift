import SwiftUI

/// Container-level bridge mounting the AppKit-owned workspace list once.
///
/// This is the only SwiftUI type in the workspace list. Everything below it —
/// scroll view, table, cells, menus, rename field, drag and drop — is AppKit
/// driven by immutable values and closures.
struct SidebarWorkspaceTableView: NSViewRepresentable {
    let rows: [SidebarWorkspaceListRow]
    let listActions: SidebarWorkspaceTableActions
    let actionResolver: SidebarWorkspaceListActionResolver
    let environment: SidebarWorkspaceListEnvironment
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

    func updateNSView(_ nsView: SidebarWorkspaceTableContainerView, context: Context) {
#if DEBUG
        context.coordinator.reconfigurationProbe = sidebarLazyContractProbe.tableRootViewReconfigure
#endif
        context.coordinator.apply(
            rows: rows,
            listActions: listActions,
            actionResolver: actionResolver,
            environment: environment,
            workspaceIds: workspaceIds,
            selectedWorkspaceId: selectedWorkspaceId,
            selectedScrollTargetWorkspaceId: selectedScrollTargetWorkspaceId
        )
    }
}
