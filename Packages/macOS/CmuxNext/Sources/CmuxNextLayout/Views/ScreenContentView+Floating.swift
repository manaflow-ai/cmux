import AppKit

/// Floating panes in the view: each one's host is above every tiled pane, docked column and divider, in the order
/// of the list, on a card of its own (`FloatingPaneCardView`).
extension ScreenContentView {
    /// One card for each floating pane of the geometry.
    func reconcileFloatingCards() {
        for (pane, card) in floatState.cards where geometry.floatingCards[pane] == nil {
            card.paintGround(of: nil, seeThrough: false)
            card.removeFromSuperview()
            floatState.cards[pane] = nil
            if floatState.drag?.pane == pane { floatState.drag = nil }
        }
        for pane in geometry.floating where floatState.cards[pane] == nil {
            let card = FloatingPaneCardView(pane: pane)
            card.onDrag = { [weak self] phase, event in self?.handleFloatingDrag(pane, phase, event: event) }
            addSubview(card)
            floatState.cards[pane] = card
        }
        // The pass that is in progress presents the cards with the look of this read; a knob's change makes one more pass.
        if !floatState.cards.isEmpty { floatState.look = floatState.lookWatch.read { [weak self] in _ = self?.reconcile(animated: false) } }
    }

    /// Puts each card around its pane's host, where that shows now. Returns true when a card moved.
    func presentFloatingCards() -> Bool {
        // A copy: a view that the pass shapes can read this view's state, and no access to it is open then.
        let state = floatState
        return state.present(in: self, hosts: context.hosts, padding: context.style.panePadding, wholeCard: context.style.floatingPanes)
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
            reconcile(animated: false, floatsOnly: true)
        case .ended:
            guard let drag = floatState.drag, drag.pane == pane else { return }
            floatState.drag = nil
            let moved = floatState.list.first { $0.pane == pane }.map { $0.frame != drag.frame } ?? false
            // Not moved, or the pane does not float any more: the view shows the model's list again.
            if !moved || !context.model.setFloatingFrame(pane, frame: drag.frame) { reconcile(animated: false, floatsOnly: true) }
        }
    }
}
