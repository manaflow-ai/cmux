import Foundation
import SwiftUI

@MainActor
struct SidebarRowSwipeCaptureView: NSViewRepresentable {
    let workspaceId: UUID
    let onOffsetChanged: (CGFloat, Bool) -> Void
    let onCommit: (SidebarRowSwipeGestureModel.Action) -> Void

    func makeNSView(context: Context) -> SidebarRowSwipeCaptureNSView {
        let view = SidebarRowSwipeCaptureNSView(workspaceId: workspaceId, frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: SidebarRowSwipeCaptureNSView, context: Context) {
        nsView.workspaceId = workspaceId
        nsView.onOffsetChanged = onOffsetChanged
        nsView.onCommit = onCommit
    }
}
