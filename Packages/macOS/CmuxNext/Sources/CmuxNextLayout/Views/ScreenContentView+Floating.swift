import AppKit

/// A screen's floating panes as its view holds them: the model's list, the cards under the panes and a pointer's
/// move or resize of one.
struct FloatingPanesState {
    enum Change { case none, frames, panes }

    /// The model's list, back to front (``LayoutScreen/floating``); set by the root before each update.
    var list: [LayoutFloatingPane] = []
    /// The list the last `update(layout:)` took.
    private var taken: [LayoutFloatingPane] = []
    /// A pointer's move or resize in progress.
    var drag: FloatingPaneDrag?
    /// The card under each floating pane.
    var cards: [PaneID: FloatingPaneCardView] = [:]

    /// What changed in the list since the last update: its panes or their order, only a frame, or nothing.
    mutating func takeChange() -> Change {
        defer { taken = list }
        if taken.map(\.pane) != list.map(\.pane) { return .panes }
        return taken == list ? .none : .frames
    }

    /// The list to place: the model's, with the frame a pointer's drag shows.
    var shown: [LayoutFloatingPane] {
        guard let drag else { return list }
        return list.map { $0.pane == drag.pane ? LayoutFloatingPane(pane: $0.pane, frame: drag.frame) : $0 }
    }
}

/// A pointer's move or resize of a floating pane: local until its release (one `setFloatingFrame` intent).
struct FloatingPaneDrag {
    var pane: PaneID
    var zone: FloatingPaneCardView.Zone
    /// Where the press was, and the card then (the screen view's coordinates).
    var startPoint: CGPoint
    var startCard: CGRect
    /// The frame the drag shows now, as fractions of the pane area.
    var frame: CGRect

    /// The frame with the pointer at `point`, in a pane area of `size`: the card moved, or the edges of the zone
    /// moved, inside the pane area and not smaller than the smallest floating pane.
    func frame(at point: CGPoint, in size: CGSize) -> CGRect {
        let dx = point.x - startPoint.x, dy = point.y - startPoint.y
        let minWidth = LayoutFloatingPane.minimumExtent * size.width, minHeight = LayoutFloatingPane.minimumExtent * size.height
        var card = startCard
        switch zone {
        case .move:
            card.origin.x = min(max(startCard.minX + dx, 0), max(0, size.width - startCard.width))
            card.origin.y = min(max(startCard.minY + dy, 0), max(0, size.height - startCard.height))
        case .left, .right, .bottom, .bottomLeft, .bottomRight:
            if zone == .left || zone == .bottomLeft {
                let minX = min(max(startCard.minX + dx, 0), startCard.maxX - minWidth)
                card.origin.x = minX
                card.size.width = startCard.maxX - minX
            }
            if zone == .right || zone == .bottomRight {
                card.size.width = min(max(startCard.width + dx, minWidth), size.width - startCard.minX)
            }
            if zone != .left, zone != .right {
                card.size.height = min(max(startCard.height + dy, minHeight), size.height - startCard.minY)
            }
        }
        return LayoutFloatingPane.clamped(LayoutFloatingPane.fractions(of: card, in: size))
    }
}

/// Floating panes in the view: each one's host is above every tiled pane, docked column and divider, in the order
/// of the list, on a card of its own (`FloatingPaneCardView`).
extension ScreenContentView {
    /// One card for each floating pane of the geometry.
    func reconcileFloatingCards() {
        for (pane, card) in floatState.cards where geometry.floatingCards[pane] == nil {
            card.removeFromSuperview()
            floatState.cards[pane] = nil
            if floatState.drag?.pane == pane { floatState.drag = nil }
        }
        for pane in geometry.floating where floatState.cards[pane] == nil {
            let card = FloatingPaneCardView(pane: pane, cornerRadius: context.style.paneCornerRadius)
            card.onDrag = { [weak self] phase, event in self?.handleFloatingDrag(pane, phase, event: event) }
            addSubview(card)
            floatState.cards[pane] = card
        }
    }

    /// Puts each card around its pane's host, where that shows now. Returns true when a card moved.
    func presentFloatingCards() -> Bool {
        var changed = false
        for (pane, card) in floatState.cards {
            guard let host = context.hosts[pane], host.superview === self else { continue }
            let frame = LayoutFloatingPane.cardRect(aroundPane: host.frame)
            if card.frame != frame {
                card.frame = frame
                changed = true
            }
            if card.isHidden != host.isHidden { card.isHidden = host.isHidden }
        }
        return changed
    }

    /// A press on a floating pane's card, its drag and its release. The drag shows in the view only; the release
    /// sends the frame once.
    func handleFloatingDrag(_ pane: PaneID, _ phase: FloatingPaneCardView.Phase, event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch phase {
        case let .began(zone):
            guard let card = geometry.floatingCards[pane], bounds.width > 0, bounds.height > 0 else { return }
            context.model.focus(pane, source: .pointer)
            floatState.drag = FloatingPaneDrag(pane: pane, zone: zone, startPoint: point, startCard: card,
                                               frame: LayoutFloatingPane.fractions(of: card, in: bounds.size))
        case .moved:
            guard var drag = floatState.drag, drag.pane == pane else { return }
            let frame = drag.frame(at: point, in: bounds.size)
            guard frame != drag.frame else { return }
            drag.frame = frame
            floatState.drag = drag
            reconcile(animated: false)
        case .ended:
            guard let drag = floatState.drag, drag.pane == pane else { return }
            floatState.drag = nil
            let moved = floatState.list.first { $0.pane == pane }.map { $0.frame != drag.frame } ?? false
            // Not moved, or the pane does not float any more: the view shows the model's list again.
            if !moved || !context.model.setFloatingFrame(pane, frame: drag.frame) { reconcile(animated: false) }
        }
    }
}
