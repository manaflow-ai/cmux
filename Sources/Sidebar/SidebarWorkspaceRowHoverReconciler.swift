import SwiftUI

struct SidebarWorkspaceRowHoverReconciler: NSViewRepresentable {
    let trackedPointerHovering: Bool
    let onPointerHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> SidebarWorkspaceRowHoverReconcilerView {
        let view = SidebarWorkspaceRowHoverReconcilerView()
        view.onPointerHoverChanged = onPointerHoverChanged
        return view
    }

    func updateNSView(_ nsView: SidebarWorkspaceRowHoverReconcilerView, context: Context) {
        nsView.onPointerHoverChanged = onPointerHoverChanged
        // Row updates can replace SwiftUI's hover state (row reuse, lifecycle
        // resets) without the pointer moving; reconcile so a disagreement with
        // pointer geometry is repaired without waiting for another mouse event.
        nsView.reconcileCurrentPointerLocation(repairing: trackedPointerHovering)
    }
}
