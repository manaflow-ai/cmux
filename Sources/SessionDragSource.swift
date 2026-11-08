import SwiftUI

/// Places one native drag source over one rendered Vault session row.
struct SessionDragSource: NSViewRepresentable {
    let entry: SessionEntry
    let beginDrag: SessionDragBeginAction
    let onDoubleClick: @MainActor () -> Void

    func makeNSView(context: Context) -> SessionDragSourceView {
        SessionDragSourceView(
            entry: entry,
            beginDrag: beginDrag,
            onDoubleClick: onDoubleClick
        )
    }

    func updateNSView(_ nsView: SessionDragSourceView, context: Context) {
        nsView.update(
            entry: entry,
            beginDrag: beginDrag,
            onDoubleClick: onDoubleClick
        )
    }
}
