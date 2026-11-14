public import AppKit

// The coordinator's handling of the mouse around its card: which events the card window takes, and
// what a press, a key or a wheel scroll seen by the dismissal monitor does.
extension HoverCardCoordinator {
    /// An interactive card's window takes the mouse only while the pointer is on the card itself.
    ///
    /// The window is the card plus a clear band (`HoverCardPanel.windowMargin`, the shadow and the
    /// slide's room, about 50 pt) that lies over the trailing part of the hovered row and the rows
    /// beside it. A window that takes the mouse there takes it from the sidebar: the list's tracking
    /// area saw the pointer leave while it still moved over its row, the row's hover went off and on
    /// as the pointer moved around it, and the pointer's moves in the band reached no source, so the
    /// card hid after the reshow window under a pointer still on its row and showed again when the
    /// pointer moved back (Leo 2026-11-06: "when you're moving your cursor around the sort of
    /// highlighted workspace, it flickers still"). Off the card the window ignores the mouse, so the
    /// sidebar sees every move; the move onto the card (`moveMonitor` sees the parent's moves while
    /// a card shows) hands the mouse to the card before its rows need it. An owner's card keeps the
    /// rule its owner set.
    func updateCardMouse() {
        guard owned == nil, let panel, panel.isInteractive else { return }
        let ignores = !(machine.shownTarget != nil && panel.isShowingCard && panel.cardFrame.contains(currentPointer()))
        if panel.ignoresMouseEvents != ignores { panel.ignoresMouseEvents = ignores }
    }

    /// One key press, click or wheel scroll seen by the dismissal monitor: it ends the card and
    /// passes the event on. Returns the event to deliver, nil when the card took it.
    ///
    /// A wheel scroll with the pointer on the shown card is the card's (Lawrence 2026-10-19,
    /// u3320: "If I open a card, move my mouse over, and start scrolling, the card just
    /// disappears"): the card ignores the mouse, so the window under it would scroll. The card
    /// scrolls its own scroll view (a long timeline) instead, stays, and the event goes no further.
    func handleMonitoredEvent(_ event: NSEvent) -> NSEvent? {
        if let panel, panel.isInteractive, panel.isShowingCard {
            let belongsToParent = event.window.map { window in
                sequence(first: window, next: \.parent).contains { $0 === panel.parent }
            } ?? false
            let pointerOnCard = panel.cardFrame.contains(currentPointer())
            if event.type == .keyDown, belongsToParent, pointerOnCard,
               let body = panel.body as? any HoverCardInteractiveBody,
               body.handleHoverCardKeyDown(event) {
                return nil
            }
            let point = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? currentPointer()
            if panel.cardFrame.contains(point) {
                if event.type == .leftMouseDown,
                   let body = panel.body as? any HoverCardInteractiveBody,
                   body.acceptsHoverCardMouse(at: point, in: panel) {
                    // Let the interactive card's row receive the click. Its
                    // action dismisses after it focuses the selected tab.
                    return event
                }
            }
        }
        if event.type == .scrollWheel, let panel, machine.shownTarget != nil, panel.isShowingCard {
            // A real event names the window under the pointer; a synthesized one may name none.
            let point = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? currentPointer()
            if panel.cardFrame.contains(point) {
                panel.scrollCard(with: event, at: point)
                return nil
            }
        }
        let reason: HoverDismissal = switch event.type {
        case .keyDown: .keyDown
        case .scrollWheel: .scrollWheel
        default: .click
        }
        dismiss(reason)
        return event
    }
}
