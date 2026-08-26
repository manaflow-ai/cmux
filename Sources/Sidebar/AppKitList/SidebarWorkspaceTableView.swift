import CmuxNotifications
import CmuxAppKitSupportUI
import SwiftUI

/// Container-level bridge mounting the AppKit-owned default workspace list once.
struct SidebarWorkspaceTableView: NSViewRepresentable {
    /// Immutable bridge input. The payload-free case leaves the controller's
    /// authoritative row/action graph untouched during interactive resize.
    enum ContentUpdate {
        case apply(
            rows: [SidebarWorkspaceTableRowConfiguration],
            actions: SidebarWorkspaceTableActions
        )
        case preserveAppliedRows
    }

    let contentUpdate: ContentUpdate
    let workspaceIds: [UUID]
    let selectedWorkspaceId: UUID?
    let selectedScrollTargetWorkspaceId: UUID?
    let isPresented: Bool
    let unreadSource: SidebarUnreadModel
    /// Invoked when a completed row click parks awaiting live actions; the
    /// owner must invalidate itself so this view re-applies (issue #9690).
    let onDeferredClickAwaitingApply: () -> Void

    @Environment(\.colorScheme) private var colorScheme

#if DEBUG
    @Environment(\.sidebarLazyContractProbe) private var sidebarLazyContractProbe
#endif

    func makeCoordinator() -> SidebarWorkspaceTableController {
        SidebarWorkspaceTableController()
    }

    func makeNSView(context: Context) -> SidebarWorkspaceTableContainerView {
        let container = context.coordinator.makeContainerView()
        container.appearance = WindowAppearanceSnapshot.appKitAppearance(for: colorScheme)
        container.emptyDropIndicatorView.colorScheme = colorScheme
        return container
    }

    func updateNSView(_ nsView: SidebarWorkspaceTableContainerView, context: Context) {
        nsView.appearance = WindowAppearanceSnapshot.appKitAppearance(for: colorScheme)
        nsView.emptyDropIndicatorView.colorScheme = colorScheme
#if DEBUG
        context.coordinator.reconfigurationProbe = sidebarLazyContractProbe.tableRootViewReconfigure
#endif
        context.coordinator.setUnreadSource(unreadSource)
        context.coordinator.onDeferredRowClickAwaitingApply = onDeferredClickAwaitingApply
        context.coordinator.setPresentationActive(isPresented, workspaceIds: workspaceIds)
        guard isPresented else { return }
        guard case let .apply(rows, actions) = contentUpdate else { return }
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
