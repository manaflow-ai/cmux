import SwiftUI

/// A vertically reorderable column of scene rows with live, Arc-style drag
/// feedback: the grabbed row lifts (scale + shadow) and follows the pointer
/// same-frame, the other rows spring aside to open the gap at the projected
/// slot as the pointer moves, and the drop settles with a spring into place.
///
/// Contrast with the system `.draggable`/`.dropDestination` approach (a
/// detached drag image and no mid-flight layout): everything here stays live
/// in the column, which is what makes it feel native.
///
/// The drop is optimistic: the component commits the new order locally (no
/// snap-back flash), reports the move to the JS runtime (`onMove` handler,
/// e.g. dispatching `workspace.reorder`), and reconciles when the authoritative
/// children order arrives from the scene.
struct ReorderableColumnView: View {
    let node: SceneNode

    @Environment(\.sceneEventSink) private var sink
    @State private var drag: DragState?
    @State private var localOrder: [String]?
    @State private var rowHeights: [String: CGFloat] = [:]

    private struct DragState: Equatable {
        let draggedId: String
        let sourceIndex: Int
        var translation: CGFloat
        var targetIndex: Int
    }

    private static let liftSpring = Animation.spring(response: 0.28, dampingFraction: 0.8)

    var body: some View {
        let order = displayOrder
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(order.enumerated()), id: \.element) { index, childId in
                SceneNodeView(nodeId: childId)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                        rowHeights[childId] = height
                    }
                    .offset(y: offset(for: childId, at: index, in: order))
                    .zIndex(drag?.draggedId == childId ? 2 : 0)
                    .scaleEffect(drag?.draggedId == childId ? 1.02 : 1)
                    .shadow(
                        color: .black.opacity(drag?.draggedId == childId ? 0.25 : 0),
                        radius: drag?.draggedId == childId ? 8 : 0,
                        y: drag?.draggedId == childId ? 3 : 0
                    )
                    .animation(drag?.draggedId == childId ? nil : Self.liftSpring, value: drag)
                    .gesture(dragGesture(childId: childId, order: order))
            }
        }
        // The authoritative order arriving (the reorder round-tripped through
        // the host command) supersedes the optimistic local copy.
        .onChange(of: node.children) { _, _ in
            if drag == nil { localOrder = nil }
        }
    }

    /// Children in display order: mid-drag and just-dropped use the local
    /// optimistic order; otherwise the scene's authoritative order.
    private var displayOrder: [String] {
        localOrder ?? node.children
    }

    private func offset(for childId: String, at index: Int, in order: [String]) -> CGFloat {
        guard let drag else { return 0 }
        if childId == drag.draggedId { return drag.translation }
        return ReorderMath.rowShift(
            index: index,
            sourceIndex: drag.sourceIndex,
            targetIndex: drag.targetIndex,
            draggedHeight: rowHeights[drag.draggedId] ?? 0
        )
    }

    private func dragGesture(childId: String, order: [String]) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                let heights = order.map { rowHeights[$0] ?? 0 }
                if drag == nil {
                    guard let sourceIndex = order.firstIndex(of: childId) else { return }
                    drag = DragState(
                        draggedId: childId,
                        sourceIndex: sourceIndex,
                        translation: 0,
                        targetIndex: sourceIndex
                    )
                }
                guard var state = drag, state.draggedId == childId else { return }
                state.translation = value.translation.height
                state.targetIndex = ReorderMath.targetIndex(
                    heights: heights,
                    sourceIndex: state.sourceIndex,
                    translation: value.translation.height
                )
                drag = state
            }
            .onEnded { _ in
                guard let state = drag, state.draggedId == childId else {
                    drag = nil
                    return
                }
                let newOrder = ReorderMath.reordered(order, from: state.sourceIndex, to: state.targetIndex)
                withAnimation(Self.liftSpring) {
                    if newOrder != order {
                        localOrder = newOrder
                    }
                    drag = nil
                }
                guard state.targetIndex != state.sourceIndex else { return }
                let key = itemKey(forChildAt: state.sourceIndex)
                sink.send(node.id, "move", ["id": key, "index": state.targetIndex])
            }
    }

    /// The item key for a row, from the `itemKeys` JSON array prop the JS
    /// reconciler keeps parallel to `children`. Falls back to the child node
    /// id when absent.
    private func itemKey(forChildAt index: Int) -> String {
        guard let json = node.string("itemKeys"),
              let data = json.data(using: .utf8),
              let keys = try? JSONDecoder().decode([String].self, from: data),
              keys.indices.contains(index),
              node.children.count == keys.count else {
            return displayOrder.indices.contains(index) ? displayOrder[index] : ""
        }
        // Keys parallel node.children; map through the child id in case the
        // display order is the optimistic local one.
        let childId = displayOrder[index]
        if let authoritativeIndex = node.children.firstIndex(of: childId) {
            return keys[authoritativeIndex]
        }
        return keys[index]
    }
}
