import AppKit

/// cmux: a host that takes a drop position in the pinned grid (Messages: drag a pinned tile
/// to a new place, or drag a row into the grid to pin it there). A host without it gets no
/// pin drags. The host changes its order and calls `reloadData()`, in the same turn for the
/// smoothest landing.
protocol SidebarPinPlacing: AnyObject {
    /// Put `id` at `index` of the grid's order (an index after `id` left its old place), pinning it if it was a row.
    func sidebar(_ sidebar: SidebarController, place id: ConversationID, at index: Int)
}

/// cmux: one drag over the pinned grid, as a value (the list keeps one while the button is
/// down). `target` is where the dragged conversation would land; nil is outside the grid.
struct SidebarPinDrag: Equatable {
    enum Source: Equatable { case tile, row }
    /// What a drop does: nothing, a new place in the grid (a move or a pin), or an unpin.
    enum Outcome: Equatable { case none, place(ConversationID, Int), unpin(ConversationID) }

    let id: ConversationID
    let source: Source
    /// The grid's order when the drag began.
    let pinned: [ConversationID]
    /// An index of `order` (clamped); nil: outside the grid.
    var target: Int?
    private(set) var cancelled = false

    init(id: ConversationID, source: Source, pinned: [ConversationID]) {
        self.id = id
        self.source = source
        self.pinned = pinned
        target = source == .tile ? pinned.firstIndex(of: id) : nil
    }

    /// The grid as it is drawn now: the others make room at `target`.
    var order: [ConversationID] {
        guard !cancelled else { return pinned }
        var order = pinned.filter { $0 != id }
        if let target { order.insert(id, at: min(max(0, target), order.count)) }
        return order
    }

    var outcome: Outcome {
        guard !cancelled else { return .none }
        guard let target else { return source == .tile ? .unpin(id) : .none }
        let place = min(max(0, target), pinned.filter { $0 != id }.count)
        if source == .tile, pinned.firstIndex(of: id) == place { return .none }
        return .place(id, place)
    }

    /// Escape: everything goes back.
    mutating func cancel() { cancelled = true }
}

/// cmux: the controller's drag in progress, its floating tile, and the landing that waits
/// for the host's reload.
final class SidebarPinDragState {
    var drag: SidebarPinDrag?
    /// The tile that follows the pointer (also for a dragged row).
    var ghost: CALayer?
    /// The pointer's offset from the ghost's center.
    var grab = CGSize.zero
    /// Where each tile was drawn at the drop (document coordinates), for the landing after the reload.
    var landing: [ConversationID: CGRect]?
    var landingID: ConversationID?
    /// The grid's drawn bottom at the drop (the rows below were shifted to it).
    var drawnGridBottom: CGFloat = 0
    static let lift: CGFloat = 1.08
}
