import SwiftUI

struct SidebarWorkspaceRowHoverReconciler: NSViewRepresentable {
    let onPointerHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> SidebarWorkspaceRowHoverReconcilerView {
        let view = SidebarWorkspaceRowHoverReconcilerView()
        view.onPointerHoverChanged = onPointerHoverChanged
        return view
    }

    func updateNSView(_ nsView: SidebarWorkspaceRowHoverReconcilerView, context: Context) {
        nsView.onPointerHoverChanged = onPointerHoverChanged
        nsView.reconcileCurrentPointerLocation()
    }
}
