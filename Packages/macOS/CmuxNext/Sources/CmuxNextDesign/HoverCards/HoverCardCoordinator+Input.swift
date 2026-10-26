import AppKit
import CmuxNextInput

// The input tap subscriptions of `HoverCardCoordinator` (p04-input-013): what ends a card and the
// pointer moves over a shown card, held only while a card is pending or shown.
extension HoverCardCoordinator {
    /// Key presses, clicks and wheel scrolls end a card: the tap observer and scroll intercept
    /// exist only while one is pending or shown.
    func updateSubscriptions() {
        let needed = machine.activeTarget != nil
        if needed, dismissals == nil, let tap = requiredInputTap(inputTap, owner: "HoverCardCoordinator") {
            let active: @MainActor () -> Bool = { [weak self] in self?.machine.activeTarget != nil }
            dismissals = tap.subscribe(class: [.key, .button], while: active) { [weak self] event in
                _ = self?.handleDismissalEvent(event)
            }
            scrolls = tap.subscribe(class: .scroll, phase: .intercept(order: .popup), while: active) { [weak self] event in
                self?.handleDismissalEvent(event) ?? .pass
            }
        } else if !needed {
            dismissals = nil
            scrolls = nil
        }
        updateCardMoves()
    }

    /// One event of the dismissal observer or scroll intercept: a key press, click or wheel scroll
    /// ends the card and passes the event on; key and button ups pass untouched. Returns `.consume`
    /// when the card took the event (only a scroll on the card).
    ///
    /// A wheel scroll with the pointer on the shown card is the card's (Lawrence 2026-10-19,
    /// u3320: "If I open a card, move my mouse over, and start scrolling, the card just
    /// disappears"): the card ignores the mouse, so the window under it would scroll. The card
    /// scrolls its own scroll view (a long timeline) instead, stays, and the event goes no further.
    func handleDismissalEvent(_ event: NSEvent) -> InputEventTap.InterceptResult {
        let reason: HoverDismissal
        switch event.type {
        case .keyDown: reason = .keyDown
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: reason = .click
        case .scrollWheel:
            reason = .scrollWheel
            if let panel, machine.shownTarget != nil, panel.isShowingCard {
                // A real event names the window under the pointer; a synthesized one may name none.
                let point = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? currentPointer()
                if panel.cardFrame.contains(point) {
                    panel.scrollCard(with: event, at: point)
                    return .consume
                }
            }
        default: return .pass
        }
        dismiss(reason)
        return .pass
    }

    /// While a card shows, pointer moves on it or just off it reach the machine: leaving the
    /// card hides it on that move (Lawrence 2026-10-19), not at the next deadline.
    private func updateCardMoves() {
        let parent = machine.shownTarget == nil ? nil : panel?.parent
        if movesParent?.window !== parent {
            if let old = movesParent { old.window.acceptsMouseMovedEvents = old.accepted }
            movesParent = parent.map { ($0, $0.acceptsMouseMovedEvents) }
            parent?.acceptsMouseMovedEvents = true
        }
        if parent != nil, cardMoves == nil, let tap = requiredInputTap(inputTap, owner: "HoverCardCoordinator.cardMoves") {
            cardMoves = tap.subscribe(class: .pointerMove, while: { [weak self] in self?.machine.shownTarget != nil }) { [weak self] event in
                self?.cardPointerMoved(event.window.map { $0.convertPoint(toScreen: event.locationInWindow) })
            }
        } else if parent == nil, cardMoves != nil {
            cardMoves = nil
            pointerWasOnCard = false
        }
    }

    /// A pointer move seen by `cardMoves`: only one on the card, or the first off it, is news
    /// (a source reports moves over its own targets itself).
    func cardPointerMoved(_ eventPoint: CGPoint?) {
        let point = eventPoint ?? pointerLocation()
        guard pointerWasOnCard || shownCardFrame?.contains(point) == true else { return }
        pointerMoved(to: point)
    }
}
