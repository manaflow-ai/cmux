import CmuxSwiftRender
import SwiftUI

/// Renders a `.reorderable` node's rows with drag-and-drop reordering.
///
/// Each row is draggable (payload = the item's id) and a drop target; dropping
/// one row onto another dispatches the reorder command from ``ReorderSpec``
/// (e.g. `workspace.reorder`), which both reorders and persists via the host.
/// No `List` is used, so it composes inside the sidebar's normal layout.
struct ReorderableList: View {
    let rows: [RenderNode]
    let spec: ReorderSpec?

    @Environment(\.sidebarActionDispatch) private var dispatch

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                RenderNodeView(node: row)
                    .draggable(itemId(index))
                    .dropDestination(for: String.self) { dropped, _ in
                        guard let draggedId = dropped.first else { return false }
                        reorder(draggedId, to: index)
                        return true
                    }
            }
        }
    }

    private func itemId(_ index: Int) -> String {
        guard let spec, index < spec.itemIds.count else { return "row-\(index)" }
        return spec.itemIds[index]
    }

    private func reorder(_ draggedId: String, to index: Int) {
        guard let spec else { return }
        dispatch.run(ButtonAction(commands: [
            .cmux(method: spec.method, params: [spec.idParam: draggedId, spec.indexParam: String(index)]),
        ]))
    }
}
