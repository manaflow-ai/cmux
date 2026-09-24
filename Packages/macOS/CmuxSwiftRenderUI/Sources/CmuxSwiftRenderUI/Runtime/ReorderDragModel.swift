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
final class ReorderDragModel {
    var localOrder: [String]?

    /// The renderer owns only the gesture preview; after settling, items win
    /// even when a refused command produces no data change.
    func finishSettlement() {
        localOrder = nil
        settledId = nil
        settledIndent = nil
        projectedIndent = nil
        draggedId = nil
        isSettling = false
        isBlockDrag = false
        blockRows = []
        isCancelling = false
    }

    @ObservationIgnored var feedback: ReorderDragFeedback?
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
    /// The dropped row and its projected indent during the settle animation.
    /// Cleared at settlement even if the authoritative data never changes.
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
