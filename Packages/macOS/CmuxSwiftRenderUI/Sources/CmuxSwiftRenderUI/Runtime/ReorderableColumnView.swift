import Observation
import SwiftUI

/// Per-drag state for ``ReorderableColumnView``, `@Observable` so invalidation
/// is exactly as fine-grained as the reads:
///
/// - `translation` changes on every pointer frame and is read ONLY by the
///   dragged row's offset, so tracking re-renders one row and animates nothing.
/// - `targetIndex` / `draggedId` are discrete: they change when the dragged
///   row's center crosses a neighbor's center (or on lift/drop), and every
///   mutation happens inside an explicit `withAnimation(spring)`. Rows shift
///   with one spring per crossing instead of a spring restarted 60×/s.
///
/// This is the first-principles jank fix: continuous state is isolated and
/// unanimated; discrete state is shared and spring-animated.
@MainActor
@Observable
private final class ReorderDragModel {
    var draggedId: String?
    var sourceIndex = 0
    var targetIndex = 0
    var translation: CGFloat = 0
    var draggedHeight: CGFloat = 0
    /// True between drop commit and settle completion: the shadow/scale lift
    /// eases out with the settle spring instead of vanishing on mouse-up.
    var isSettling = false
}

/// A vertically reorderable column of scene rows with Arc-style drag feedback:
/// the grabbed row lifts (scale + shadow) and tracks the pointer same-frame,
/// the other rows spring aside exactly once per slot crossing, and the drop
/// commits the new order with visual continuity (the row settles from where
/// it visually is into its new slot; nothing jumps or double-animates).
///
/// The drop is optimistic: the new order is committed locally and reported to
/// the JS runtime (`onMove`, e.g. `workspace.reorder`); the authoritative
/// children order reconciles afterwards.
struct ReorderableColumnView: View {
    let node: SceneNode

    @Environment(\.sceneStore) private var store
    @Environment(\.sceneEventSink) private var sink
    @State private var model = ReorderDragModel()
    @State private var localOrder: [String]?
    @State private var rowHeights: [String: CGFloat] = [:]

    /// stderr trace of lift/crossing/drop, enabled with CMUX_REORDER_DEBUG=1.
    private static let debugEnabled = ProcessInfo.processInfo.environment["CMUX_REORDER_DEBUG"] == "1"

    private static func debugLog(_ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        FileHandle.standardError.write(Data("reorder: \(message())\n".utf8))
    }

    private static let gapSpring = Animation.spring(response: 0.25, dampingFraction: 0.78)
    private static let liftSpring = Animation.spring(response: 0.2, dampingFraction: 0.8)
    private static let settleSpring = Animation.spring(response: 0.32, dampingFraction: 0.76)

    /// Inter-row spacing (the `spacing` option of `Reorderable`), also fed
    /// into the geometry so slot math matches the layout.
    private var rowSpacing: CGFloat {
        CGFloat(node.double("spacing") ?? 0)
    }

    var body: some View {
        let order = displayOrder
        VStack(alignment: .leading, spacing: rowSpacing) {
            ForEach(Array(order.enumerated()), id: \.element) { index, childId in
                ReorderableRowView(
                    childId: childId,
                    index: index,
                    model: model,
                    spacing: rowSpacing
                )
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                    rowHeights[childId] = height
                }
                .highPriorityGesture(dragGesture(childId: childId))
            }
        }
        // The authoritative order arriving (the reorder round-tripped through
        // the host command) supersedes the optimistic local copy.
        .onChange(of: node.children) { _, _ in
            if model.draggedId == nil { localOrder = nil }
        }
    }

    /// Children in display order: mid-drag and just-dropped use the local
    /// optimistic order; otherwise the scene's authoritative order. A
    /// contextMenu child attached to the list itself is never a row.
    private var displayOrder: [String] {
        (localOrder ?? node.children).filter { store?.node($0)?.type != "contextMenu" }
    }

    private func dragGesture(childId: String) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let order = displayOrder
                if model.draggedId == nil {
                    guard let sourceIndex = order.firstIndex(of: childId) else { return }
                    // Freeze the visual order for the whole gesture: a live
                    // data update mid-drag must not reshuffle rows under the
                    // pointer. onChange(node.children) reconciles after drop.
                    if localOrder == nil {
                        localOrder = order
                    }
                    // Lift: scale/shadow spring in; nothing else moves yet.
                    withAnimation(Self.liftSpring) {
                        model.draggedId = childId
                        model.isSettling = false
                    }
                    model.sourceIndex = sourceIndex
                    model.targetIndex = sourceIndex
                    model.draggedHeight = rowHeights[childId] ?? 0
                    Self.debugLog("lift id=\(childId) source=\(sourceIndex) height=\(model.draggedHeight) heights=\(order.map { rowHeights[$0] ?? 0 })")
                }
                guard model.draggedId == childId else { return }
                // Continuous: tracks the pointer, deliberately unanimated.
                model.translation = value.translation.height
                // Discrete: one spring per slot crossing, with hysteresis so
                // pointer jitter on a boundary can't flip-flop the target.
                let target = ReorderMath.targetIndex(
                    heights: order.map { rowHeights[$0] ?? 0 },
                    sourceIndex: model.sourceIndex,
                    translation: value.translation.height,
                    current: model.targetIndex,
                    spacing: rowSpacing
                )
                if target != model.targetIndex {
                    Self.debugLog("cross translation=\(value.translation.height) target \(model.targetIndex) -> \(target)")
                    withAnimation(Self.gapSpring) {
                        model.targetIndex = target
                    }
                }
            }
            .onEnded { _ in
                guard model.draggedId == childId else { return }
                drop(childId: childId)
            }
    }

    /// Commits the drop with visual continuity: reorder the array with NO
    /// animation while giving the dragged row a residual offset equal to its
    /// current visual displacement from its new slot, then spring that
    /// residual to zero.
    private func drop(childId: String) {
        let order = displayOrder
        let heights = order.map { rowHeights[$0] ?? 0 }
        let source = model.sourceIndex
        let target = model.targetIndex
        let newOrder = ReorderMath.reordered(order, from: source, to: target)

        // Visual position now: old slot top + pointer translation.
        // New layout position: slot top at `target` in the new order.
        let residual = ReorderMath.settleResidual(
            heights: heights,
            sourceIndex: source,
            targetIndex: target,
            translation: model.translation,
            spacing: rowSpacing
        )

        // Phase 1, no animation: the array order, source/target, and residual
        // all change in one transaction so every row's layout position equals
        // its current visual position. The screen does not change this frame.
        var commit = Transaction()
        commit.disablesAnimations = true
        withTransaction(commit) {
            if newOrder != order {
                localOrder = newOrder
            }
            model.sourceIndex = target
            model.targetIndex = target
            model.translation = residual
        }

        // Phase 2, settle spring: the residual eases to zero and the lift
        // (scale/shadow) eases out with it. draggedId clears on completion so
        // zIndex stays raised while the row is still visually settling.
        withAnimation(Self.settleSpring) {
            model.translation = 0
            model.isSettling = true
        } completion: {
            model.draggedId = nil
            model.isSettling = false
        }

        Self.debugLog("drop source=\(source) target=\(target) translation-residual=\(residual)")
        guard target != source else { return }
        sink.send(node.id, "move", ["id": itemKey(forChildAt: target, in: newOrder), "index": target])
    }

    /// The item key for the row at `index` of `order`, from the `itemKeys`
    /// JSON array prop the JS reconciler keeps parallel to `node.children`.
    /// Falls back to the child node id when absent.
    private func itemKey(forChildAt index: Int, in order: [String]) -> String {
        guard order.indices.contains(index) else { return "" }
        let childId = order[index]
        let rows = node.children.filter { store?.node($0)?.type != "contextMenu" }
        guard let json = node.string("itemKeys"),
              let data = json.data(using: .utf8),
              let keys = try? JSONDecoder().decode([String].self, from: data),
              rows.count == keys.count,
              let authoritativeIndex = rows.firstIndex(of: childId) else {
            return childId
        }
        return keys[authoritativeIndex]
    }
}

/// One row of the reorderable column. Reads the drag model with per-property
/// granularity: non-dragged rows read only the discrete fields, so pointer
/// tracking (translation) re-renders exactly one row.
private struct ReorderableRowView: View {
    let childId: String
    let index: Int
    let model: ReorderDragModel
    let spacing: CGFloat

    var body: some View {
        // Read discrete fields first; `translation` is only read on the
        // dragged row's branch, so other rows never depend on it.
        let draggedId = model.draggedId
        let isDragged = draggedId == childId
        let lifted = isDragged && !model.isSettling
        SceneNodeView(nodeId: childId)
            .offset(y: offset(isDragged: isDragged, dragging: draggedId != nil))
            .zIndex(isDragged ? 2 : 0)
            .scaleEffect(lifted ? 1.02 : 1)
            .shadow(
                color: .black.opacity(lifted ? 0.25 : 0),
                radius: lifted ? 8 : 0,
                y: lifted ? 3 : 0
            )
    }

    private func offset(isDragged: Bool, dragging: Bool) -> CGFloat {
        if isDragged {
            return model.translation
        }
        guard dragging else { return 0 }
        return ReorderMath.rowShift(
            index: index,
            sourceIndex: model.sourceIndex,
            targetIndex: model.targetIndex,
            draggedHeight: model.draggedHeight,
            spacing: spacing
        )
    }
}
