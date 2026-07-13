import SwiftUI

struct SidebarWorkspaceRowMenuTrackingReconciler: NSViewRepresentable {
    let onMenuTrackingEnded: (Bool) -> Void

    func makeNSView(context: Context) -> SidebarWorkspaceRowMenuTrackingReconcilerView {
        let view = SidebarWorkspaceRowMenuTrackingReconcilerView()
        view.onMenuTrackingEnded = onMenuTrackingEnded
        return view
    }

    func updateNSView(_ nsView: SidebarWorkspaceRowMenuTrackingReconcilerView, context: Context) {
        nsView.onMenuTrackingEnded = onMenuTrackingEnded
    }
}
