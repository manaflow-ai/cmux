import SwiftUI

@MainActor
struct SidebarRowSwipeCaptureView: NSViewRepresentable {
    let onOffsetChanged: (CGFloat, Bool) -> Void
    let onCommit: (SidebarRowSwipeGestureModel.Action) -> Void

    func makeNSView(context: Context) -> SidebarRowSwipeCaptureNSView {
        let view = SidebarRowSwipeCaptureNSView(frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: SidebarRowSwipeCaptureNSView, context: Context) {
        nsView.onOffsetChanged = onOffsetChanged
        nsView.onCommit = onCommit
    }
}
