import SwiftUI

/// Keeps the reserved traffic-light area draggable when both title and sidebar
/// are hidden. The pane-tab area retains its standard click/double-click actions.
struct WorkspaceTitlebarDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> WorkspaceTitlebarDragView {
        WorkspaceTitlebarDragView()
    }

    func updateNSView(_ nsView: WorkspaceTitlebarDragView, context: Context) {}
}
