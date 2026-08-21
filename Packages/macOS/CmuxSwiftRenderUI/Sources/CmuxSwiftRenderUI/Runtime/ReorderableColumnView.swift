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
    /// The leading indent of the projected drop slot (Arc-style X preview):
    /// while dragging toward a group the row slides to the member indent,
    /// dragging out it slides back. `nil` = no evidence, keep current X.
    var projectedIndent: CGFloat?
    /// The last drop's row and projected indent, kept after the drag ends so
    /// the X preview holds until the authoritative data lands (the row's own
    /// indent prop then matches the projection and the offset becomes zero).
    var settledId: String?
    var settledIndent: CGFloat?
    /// True while an Escape-cancelled drag springs home; gesture events are
    /// ignored until the settle completes.
    var isCancelling = false
    /// Local Escape key monitor, alive only while a drag is in flight.
    @ObservationIgnored var escapeMonitor: Any?
    /// Which neighbor's nesting the ambiguous boundary slot resolved to
    /// ("above" or "below"), chosen by the pointer's X position.
    var boundarySide = "above"
    /// The dragged row's indent at lift, the X reference for boundary choice.
    var liftIndent: CGFloat = 0

    /// Block mode: grabbing a block head (a `fixed` row with a `block` prop)
    /// drags the whole run of rows sharing that block value as one unit.
    var isBlockDrag = false
    /// Rows moving with the drag in block mode (head + members).
    var blockRows: Set<String> = []
    /// Frozen at lift: each row's index in the coarse item list, where the
    /// dragged block (and every other block) is one item.
    var coarseIndexByRow: [String: Int] = [:]
    var coarseSource = 0
    var coarseTarget = 0
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
    // Deliberately NOT @State: slot heights change EVERY FRAME during the
    // accordion fold, and observing them would re-render the whole column
    // per frame. Geometry is only read at gesture time.
    @State private var rowHeights = RowHeightsBox()

    /// stderr trace of lift/crossing/drop, enabled with CMUX_REORDER_DEBUG=1.
    private static let debugEnabled = ProcessInfo.processInfo.environment["CMUX_REORDER_DEBUG"] == "1"

    private static func debugLog(_ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        FileHandle.standardError.write(Data("reorder: \(message())\n".utf8))
    }

    private static let gapSpring = Animation.spring(response: 0.25, dampingFraction: 0.78)
    /// Critically damped on purpose: any spring overshoot makes the per-row
    /// masks visibly stutter at each row boundary during the fold.
    private static let accordionSpring = Animation.spring(response: 0.26, dampingFraction: 1.0)
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
                    rowHeights.record(childId, height)
                }
                // A `fixed` row is not draggable itself (masking to
                // .subviews keeps its taps/chevrons working) UNLESS it is a
                // block head (`fixed` + `block`): grabbing a head drags the
                // whole block.
                .highPriorityGesture(
                    dragGesture(childId: childId),
                    including: rowIsGrabbable(childId) ? .all : .subviews
                )

                // Accordion: the slot's animating height masks the row at
                // constant row height (fixedSize + clipped in
                // ReorderableRowView, so no squish), and the row fades
                // quickly as it enters/leaves - the fade runs its own faster
                // curve than the fold.
                .transition(.opacity.animation(.easeOut(duration: 0.12)))
            }
        }
        // Animate DATA-driven structural changes (collapse/expand, external
        // reorders, a bulk drop's gather during the settle) so rows glide
        // instead of popping. Never while tracking a drag: the drop commit
        // relies on an unanimated transaction, which runs before isSettling
        // flips on.
        .animation(model.draggedId == nil || model.isSettling ? Self.accordionSpring : nil, value: displayOrder)
        // The authoritative order arriving (the reorder round-tripped through
        // the host command) supersedes the optimistic local copy. This must
        // also happen DURING the settle: a bulk drop's optimistic gather
        // (the JS reorders children the moment the drop dispatches) would
        // otherwise stay masked behind the frozen local order until the
        // slower socket echo arrived.
        .onChange(of: node.children) { _, _ in
            if model.draggedId == nil || model.isSettling { localOrder = nil }
        }
        // Suppress hover washes on every row but the dragged one while a
        // drag is in flight (see SceneBoxStyle).
        .environment(\.sceneDraggedNodeId, model.draggedId)
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
                if model.isCancelling { return }
                if model.draggedId == nil {
                    guard let sourceIndex = order.firstIndex(of: childId) else { return }
                    // Freeze the visual order for the whole gesture: a live
                    // data update mid-drag must not reshuffle rows under the
                    // pointer. onChange(node.children) reconciles after drop.
                    if localOrder == nil {
                        localOrder = order
                    }
                    // Lift: shadow springs in; nothing else moves yet.
                    withAnimation(Self.liftSpring) {
                        model.draggedId = childId
                        model.isSettling = false
                    }
                    model.projectedIndent = nil
                    model.settledId = nil
                    model.settledIndent = nil
                    model.boundarySide = "above"
                    model.liftIndent = rowIndent(childId)
                    let node = store?.node(childId)
                    model.isBlockDrag = node?.bool("fixed") == true && node?.string("block") != nil
                    if model.isBlockDrag {
                        // Coarse structure: every block is one item, so a
                        // block can never drop inside another block.
                        let items = coarseItems(order: order)
                        var indexByRow: [String: Int] = [:]
                        for (i, item) in items.enumerated() {
                            for row in item { indexByRow[row] = i }
                        }
                        model.coarseIndexByRow = indexByRow
                        let sourceItem = indexByRow[childId] ?? 0
                        model.coarseSource = sourceItem
                        model.coarseTarget = sourceItem
                        model.blockRows = Set(items[sourceItem])
                        model.draggedHeight = itemHeight(items[sourceItem])
                        model.sourceIndex = sourceItem
                        model.targetIndex = sourceItem
                    } else {
                        model.isBlockDrag = false
                        model.blockRows = []
                        model.sourceIndex = sourceIndex
                        model.targetIndex = sourceIndex
                        model.draggedHeight = rowHeights.height(childId)
                    }
                    Self.debugLog("lift id=\(childId) source=\(sourceIndex) block=\(model.isBlockDrag) height=\(model.draggedHeight)")
                    installEscapeMonitor()
                }
                guard model.draggedId == childId else { return }
                // Continuous: tracks the pointer, deliberately unanimated.
                model.translation = value.translation.height

                if model.isBlockDrag {
                    // Blocks target over the coarse item list; no X preview
                    // (blocks stay at the top level).
                    let items = coarseItems(order: order)
                    let target = ReorderMath.targetIndex(
                        heights: items.map { itemHeight($0) },
                        sourceIndex: model.coarseSource,
                        translation: value.translation.height,
                        current: model.coarseTarget,
                        spacing: rowSpacing
                    )
                    if target != model.coarseTarget {
                        Self.debugLog("block cross target \(model.coarseTarget) -> \(target)")
                        withAnimation(Self.gapSpring) {
                            model.coarseTarget = target
                            model.targetIndex = target
                        }
                    }
                    return
                }

                // Discrete: one spring per slot crossing, with hysteresis so
                // pointer jitter on a boundary can't flip-flop the target.
                let heights = order.map { rowHeights.height($0) }
                let indents = order.map { rowIndent($0) }
                let fixedFlags = order.map { store?.node($0)?.bool("fixed") == true }
                let target = ReorderMath.targetIndex(
                    heights: heights,
                    sourceIndex: model.sourceIndex,
                    translation: value.translation.height,
                    current: model.targetIndex,
                    spacing: rowSpacing
                )
                // An ambiguous slot (e.g. right after a group's last member)
                // has two nestings; the pointer's X position picks one, with
                // hysteresis. The X preview animates in the same spring as
                // the gap.
                let (above, below) = ReorderMath.boundaryIndents(
                    indents: indents,
                    fixed: fixedFlags,
                    sourceIndex: model.sourceIndex,
                    targetIndex: target
                )
                let side = ReorderMath.boundarySide(
                    above: above,
                    below: below,
                    pointerX: model.liftIndent + value.translation.width,
                    current: model.boundarySide
                )
                let projected = side == "below" ? below : above
                if target != model.targetIndex || side != model.boundarySide || projected != model.projectedIndent {
                    Self.debugLog("cross target \(model.targetIndex)->\(target) side=\(side) indent=\(String(describing: projected))")
                    withAnimation(Self.gapSpring) {
                        model.targetIndex = target
                        model.boundarySide = side
                        model.projectedIndent = projected
                    }
                }
            }
            .onEnded { _ in
                guard model.draggedId == childId, !model.isCancelling else { return }
                drop(childId: childId)
            }
    }

    /// Escape cancels an in-flight drag: the dragged rows spring back to
    /// their original slot and X level, and nothing is dispatched. The key
    /// monitor exists only between lift and drop/cancel and swallows the
    /// Escape it consumes.
    private func installEscapeMonitor() {
        removeEscapeMonitor()
        let model = model
        model.escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, model.draggedId != nil, !model.isCancelling else {
                return event
            }
            cancelDrag()
            return nil
        }
    }

    private func removeEscapeMonitor() {
        if let monitor = model.escapeMonitor {
            NSEvent.removeMonitor(monitor)
            model.escapeMonitor = nil
        }
    }

    private func cancelDrag() {
        guard model.draggedId != nil, !model.isCancelling else { return }
        Self.debugLog("cancel drag")
        model.isCancelling = true
        removeEscapeMonitor()
        withAnimation(Self.settleSpring) {
            model.translation = 0
            model.targetIndex = model.sourceIndex
            model.coarseTarget = model.coarseSource
            model.projectedIndent = nil
            model.isSettling = true
        } completion: {
            model.draggedId = nil
            model.isSettling = false
            model.isBlockDrag = false
            model.blockRows = []
            model.isCancelling = false
        }
    }

    /// Commits the drop with visual continuity: reorder the array with NO
    /// animation while giving the dragged rows a residual offset equal to
    /// their current visual displacement from the new slot, then spring that
    /// residual to zero.
    private func drop(childId: String) {
        removeEscapeMonitor()
        let order = displayOrder
        let isBlock = model.isBlockDrag
        let items = isBlock ? coarseItems(order: order) : order.map { [$0] }
        let heights = items.map { itemHeight($0) }
        let source = isBlock ? model.coarseSource : model.sourceIndex
        let target = isBlock ? model.coarseTarget : model.targetIndex
        let newItems = ReorderMath.reordered(items, from: source, to: target)
        let newOrder = newItems.flatMap { $0 }

        // Visual position now: old slot top + pointer translation.
        // New layout position: slot top at `target` in the new item order.
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
            model.coarseSource = target
            model.coarseTarget = target
            model.translation = residual
        }

        // Phase 2, settle spring: the residual eases to zero and the lift
        // shadow eases out with it. draggedId clears on completion so zIndex
        // stays raised while the rows are still visually settling.
        withAnimation(Self.settleSpring) {
            model.translation = 0
            model.isSettling = true
        } completion: {
            model.draggedId = nil
            model.isSettling = false
            model.isBlockDrag = false
            model.blockRows = []
        }
        // Hold the X preview past the settle: the offset formula
        // (projected - own indent prop) self-zeroes when the authoritative
        // data updates the row's indent, so there is never a horizontal jump.
        model.settledId = childId
        model.settledIndent = model.projectedIndent

        Self.debugLog("drop block=\(isBlock) source=\(source) target=\(target) side=\(model.boundarySide) residual=\(residual)")
        guard target != source || model.boundarySide == "below" else { return }
        // The reported index is the dragged row's flat slot in the new order.
        let flatIndex = newOrder.firstIndex(of: childId) ?? target
        sink.send(node.id, "move", [
            "id": itemKey(forChild: childId),
            "index": flatIndex,
            "side": model.boundarySide,
            "block": isBlock,
        ])
    }

    /// Consecutive rows sharing a `block` prop value merge into one coarse
    /// item; other rows are singleton items.
    private func coarseItems(order: [String]) -> [[String]] {
        var items: [[String]] = []
        var currentBlock: String?
        for row in order {
            let block = store?.node(row)?.string("block")
            if let block, block == currentBlock, !items.isEmpty {
                items[items.count - 1].append(row)
            } else {
                items.append([row])
                currentBlock = block
            }
        }
        return items
    }

    /// A coarse item's visual height: its rows plus the inter-row spacing
    /// inside the item (inter-item spacing matches row spacing, so the slot
    /// math stays exact).
    private func itemHeight(_ rows: [String]) -> CGFloat {
        let total = rows.reduce(CGFloat(0)) { $0 + rowHeights.height($1) }
        return total + rowSpacing * CGFloat(max(0, rows.count - 1))
    }

    /// Whether grabbing this row starts a drag: normal rows always; fixed
    /// rows only when they head a block.
    private func rowIsGrabbable(_ id: String) -> Bool {
        guard let rowNode = store?.node(id) else { return false }
        if !rowNode.bool("fixed") { return true }
        return rowNode.string("block") != nil
    }

    /// A row's nesting indent: its outer leading margin. (paddingLeading is
    /// content inset inside a full-width box and does not define nesting.)
    private func rowIndent(_ id: String) -> CGFloat {
        CGFloat(store?.node(id)?.double("marginLeading") ?? 0)
    }

    /// The item key for a row, from the `itemKeys` JSON array prop the JS
    /// reconciler keeps parallel to `node.children`. Falls back to the child
    /// node id when absent.
    private func itemKey(forChild childId: String) -> String {
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

/// Row-height store for gesture-time geometry. A plain class on purpose:
/// observing heights from a view would re-render the whole column whenever a
/// slot resizes; geometry is only ever read at gesture time. (Enter/exit slot
/// animations are interpolated by the render server - onGeometryChange only
/// reports settled values - so animation frames never touch this path or the
/// main thread.)
@MainActor
final class RowHeightsBox {
    private var heights: [String: CGFloat] = [:]

    func record(_ id: String, _ height: CGFloat) {
        heights[id] = height
    }

    func height(_ id: String) -> CGFloat {
        heights[id] ?? 0
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

    @Environment(\.sceneStore) private var store

    var body: some View {
        // Read discrete fields first; `translation` is only read on the
        // moving rows' branch, so other rows never depend on it.
        let draggedId = model.draggedId
        let isDragged = draggedId == childId
        let moves = isDragged || (model.isBlockDrag && draggedId != nil && model.blockRows.contains(childId))
        let lifted = isDragged && !model.isSettling
        SceneNodeView(nodeId: childId)
            // A moving row gets a material backdrop so it stays readable
            // while passing over other rows (and blurs them glass-style);
            // at rest rows stay transparent so the surface shows through.
            // The shape matches the row's own box (its corner radius, inset
            // by its leading margin).
            .background {
                // No backdrop by default: the row must look exactly as it
                // does at rest while dragging (its background must not
                // change). A sidebar that wants a fill under the lifted row
                // opts in with a dragBackground color token (stable color,
                // never a material - materials resample what they pass over
                // and flash).
                if moves, let fill = dslColor(store?.node(childId)?.string("dragBackground")) {
                    RoundedRectangle(
                        cornerRadius: CGFloat(store?.node(childId)?.double("cornerRadius") ?? 8),
                        style: .continuous
                    )
                    .fill(fill)
                    .padding(.leading, CGFloat(store?.node(childId)?.double("marginLeading") ?? 0))
                }
            }
            // Nesting preview: a leading-PADDING delta, not a translation, so
            // the dragged row's box narrows from the left with its right edge
            // fixed — exactly the geometry of a row whose marginLeading is the
            // projected indent. Its own margin still applies, so the delta
            // self-zeroes when the authoritative data lands.
            .padding(.leading, indentDelta(isDragged: isDragged))
            // Accordion mask: during collapse/expand the row's SLOT height
            // animates, but the row itself must not squish. fixedSize keeps
            // the row at intrinsic height; the top-aligned frame + clipped
            // masks it against the animating slot, so it slides under the
            // row above instead of compressing.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .clipped()
            // The Y offset is its own modifier: it updates un-animated every
            // pointer frame and must not share an animatable value with the
            // animated nesting preview.
            .offset(y: yOffset(moves: moves, dragging: draggedId != nil))
            .zIndex(moves ? 2 : 0)
            // No scale zoom on lift (dogfood feedback): the shadow alone
            // carries the lifted affordance.
            .shadow(
                color: .black.opacity(lifted ? 0.25 : 0),
                radius: lifted ? 8 : 0,
                y: lifted ? 3 : 0
            )
    }

    /// Arc-style nesting preview: the dragged row's box insets to the
    /// projected slot's indent; after the drop the delta holds until the
    /// row's own marginLeading catches up (projected - current then equals
    /// zero, so nothing jumps on reconcile).
    private func indentDelta(isDragged: Bool) -> CGFloat {
        let projected: CGFloat?
        if isDragged {
            projected = model.projectedIndent
        } else if model.settledId == childId {
            projected = model.settledIndent
        } else {
            projected = nil
        }
        guard let projected, let node = store?.node(childId) else { return 0 }
        return projected - CGFloat(node.double("marginLeading") ?? 0)
    }

    private func yOffset(moves: Bool, dragging: Bool) -> CGFloat {
        if moves {
            return model.translation
        }
        guard dragging else { return 0 }
        if model.isBlockDrag {
            guard let coarseIndex = model.coarseIndexByRow[childId] else { return 0 }
            return ReorderMath.rowShift(
                index: coarseIndex,
                sourceIndex: model.coarseSource,
                targetIndex: model.coarseTarget,
                draggedHeight: model.draggedHeight,
                spacing: spacing
            )
        }
        return ReorderMath.rowShift(
            index: index,
            sourceIndex: model.sourceIndex,
            targetIndex: model.targetIndex,
            draggedHeight: model.draggedHeight,
            spacing: spacing
        )
    }
}
