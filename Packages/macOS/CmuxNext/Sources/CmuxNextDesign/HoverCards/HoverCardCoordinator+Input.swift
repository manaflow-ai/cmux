import AppKit
import CmuxNextInput
import CmuxNextWakeups

// The input tap subscriptions of `HoverCardCoordinator`: what ends a card and the
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
    /// when the card took the event (only a scroll on the card). A press on a shown card that takes
    /// clicks (``HoverCardBody/interactive``) leaves it up: the press runs this observer before AppKit
    /// hands it to the card's button, so ending the card here would take the button from under it.
    ///
    /// A wheel scroll with the pointer on the shown card is the card's (Lawrence 2026-10-19,
    /// u3320: "If I open a card, move my mouse over, and start scrolling, the card just
    /// disappears"): the card ignores the mouse, so the window under it would scroll. The card
    /// scrolls its own scroll view (a long timeline) instead, stays, and the event goes no further.
    func handleDismissalEvent(_ event: NSEvent) -> InputEventTap.InterceptResult {
        let reason: HoverDismissal
        switch event.type {
        case .keyDown: reason = .keyDown
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            reason = .click
            // A press on a card that takes clicks (a tab card's Discard) is the card's: it goes on to the card's
            // button, whose action ends the card (`dismiss(.action)`).
            if panel?.isInteractive == true, pointOnShownCard(event) != nil { return .pass }
        case .scrollWheel:
            reason = .scrollWheel
            if let panel, let point = pointOnShownCard(event) {
                panel.scrollCard(with: event, at: point)
                return .consume
            }
        default: return .pass
        }
        dismiss(reason)
        return .pass
    }

    /// Where `event` happened on screen, when that is on the shown card (not one that fades); else nil.
    private func pointOnShownCard(_ event: NSEvent) -> CGPoint? {
        guard let panel, machine.shownTarget != nil, panel.isShowingCard else { return nil }
        // A real event names the window under the pointer; a synthesized one may name none.
        let point = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? currentPointer()
        return panel.cardFrame.contains(point) ? point : nil
    }

    /// While a card shows, pointer moves on it or just off it reach the machine: leaving the
    /// card hides it on that move (Lawrence 2026-10-19), not at the next deadline.
    ///
    /// With the parent's frames (``HoverFrameInputHosting``, feature `pointerFrameHover`) the moves
    /// reach it on the parent's frame: the first of a frame interval in its own turn, the rest once at
    /// the frame, at the latest point, as Chromium delivers rAF-aligned moves
    /// (`third_party/blink/renderer/platform/widget/input/main_thread_event_queue.cc`). A key press or a
    /// click flushes them before it dismisses the card (``FrameInputCoalescers/willDispatch(_:)``).
    private func updateCardMoves() {
        let parent = machine.shownTarget == nil ? nil : panel?.parent
        if movesParent?.window !== parent {
            if let old = movesParent { old.window.acceptsMouseMovedEvents = old.accepted }
            movesParent = parent.map { ($0, $0.acceptsMouseMovedEvents) }
            parent?.acceptsMouseMovedEvents = true
            cardMoveFrames?.cancel()
            cardMoveFrames = parent.flatMap { cardMoveConsumer(on: $0) }
        }
        if parent != nil, cardMoves == nil, let tap = requiredInputTap(inputTap, owner: "HoverCardCoordinator.cardMoves") {
            cardMoves = tap.subscribe(class: .pointerMove, while: { [weak self] in self?.machine.shownTarget != nil }) { [weak self] event in
                self?.cardMoveEvent(event)
            }
        } else if parent == nil, cardMoves != nil {
            cardMoves = nil
            pointerWasOnCard = false
        }
    }

    /// The card moves' consumer on `parent`'s coalescer; nil while the parent carries no frames.
    private func cardMoveConsumer(on parent: NSWindow) -> PointerFrameConsumer? {
        guard let frames = (parent as? HoverFrameInputHosting)?.hoverFrameInput else { return nil }
        return frames.coalescer(for: parent).consumer(owner: "HoverCardCoordinator.cardMoves") { [weak self] input in
            guard let self, machine.shownTarget != nil else { return }
            cardPointerMoved(CGPoint(x: input.latest.screenLocation.x, y: input.latest.screenLocation.y))
        }
    }

    /// A move seen by `cardMoves`: it waits for the parent's frame, or reaches the card now.
    func cardMoveEvent(_ event: NSEvent) {
        if let cardMoveFrames, cardMoveFrames.post(event) { return }
        cardPointerMoved(event.window.map { $0.convertPoint(toScreen: event.locationInWindow) })
    }

    /// A pointer move seen by `cardMoves`: only one on the card, or the first off it, is news
    /// (a source reports moves over its own targets itself).
    func cardPointerMoved(_ eventPoint: CGPoint?) {
        cardMoveChecks += 1
        let point = eventPoint ?? pointerLocation()
        guard pointerWasOnCard || shownCardFrame?.contains(point) == true else { return }
        pointerMoved(to: point)
    }
}
