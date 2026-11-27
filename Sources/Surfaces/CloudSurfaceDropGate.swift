import SwiftUI

/// Covers Bonsplit's SwiftUI/tab-strip destinations; portal panes use the same policy.
struct CloudSurfaceDropGate: NSViewRepresentable {
    let workspaceID: UUID
    let isActive: Bool

    func makeNSView(context: Context) -> CloudSurfaceDropGateView {
        CloudSurfaceDropGateView(frame: .zero)
    }

    func updateNSView(_ view: CloudSurfaceDropGateView, context: Context) {
        view.workspace = Workspace.liveWorkspace(id: workspaceID)
        view.isActive = isActive
    }

    static func dismantleNSView(_ view: CloudSurfaceDropGateView, coordinator: ()) {
        view.feedback.clear()
    }
}
