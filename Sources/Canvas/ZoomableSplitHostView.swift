import SwiftUI

/// Hosts the packed Bonsplit tree inside a single zoomable AppKit viewport.
///
/// Bonsplit remains the source of truth for pane placement. This wrapper only
/// changes the viewport around the split tree: pan/zoom/reveal/overview operate
/// on the whole packed layout as one document.
struct ZoomableSplitHostView: NSViewRepresentable {
    let workspace: Workspace
    let isWorkspaceInputActive: Bool
    let content: AnyView

    func makeNSView(context: Context) -> ZoomableSplitRootView {
        ZoomableSplitRootView(
            workspace: workspace,
            isWorkspaceInputActive: isWorkspaceInputActive,
            content: content
        )
    }

    func updateNSView(_ nsView: ZoomableSplitRootView, context: Context) {
        nsView.update(
            isWorkspaceInputActive: isWorkspaceInputActive,
            content: content
        )
    }

    static func dismantleNSView(_ nsView: ZoomableSplitRootView, coordinator: ()) {
        nsView.teardown()
    }
}
