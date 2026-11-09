import AppKit

/// The pointer in the clear band around an interactive card (the shadow and the slide's room,
/// `windowMargin`) is over what the card sits beside, for hover as for clicks
/// (`HoverCardPanel+ClickThrough`). The band of the update card's notes reaches over the update
/// card's top right corner, where its x is (Aziz 2026-11-09: "The x here doesnt appear when the
/// cursor is in the top right").
///
/// Two parts: the hover's topmost check looks through the band (``PointerClearBandWindow``), and
/// since the parent window hears no pointer moves while this window is over the point, a move,
/// enter or exit in the band recomputes the parent's hover (`PointerHover.refresh(in:)`) and tells
/// the window's other hovers (`PointerBandFollower`: the layout's dividers).
extension HoverCardPanel: PointerClearBandWindow {
    /// Outside the drawn card (where a slide or morph has it now), as presses are forwarded there.
    func passesPointer(atScreen screenPoint: NSPoint) -> Bool {
        !isVisible || !presentedCardFrame.contains(screenPoint)
    }

    /// Tracks the pointer over the whole window while the card takes the mouse (an interactive card;
    /// a click-through one passes the pointer to the window below by itself).
    func installBandRelayIfNeeded() {
        guard bandRelay == nil, let content = contentView else { return }
        let relay = HoverCardBandRelay(panel: self)
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: relay)
        content.addTrackingArea(area)
        bandRelay = relay
    }
}

/// The band's tracking area owner: refreshes the parent window's hover (``HoverCardPanel+PointerBand``).
@MainActor
final class HoverCardBandRelay: NSObject {
    private weak var panel: HoverCardPanel?
    /// The pointer was in the band at the last event: a move onto the card refreshes once more, so a
    /// hover under the band ends there.
    private var wasInBand = false

    init(panel: HoverCardPanel) {
        self.panel = panel
    }

    // Not an NSResponder: the selectors are named (cx-2mp6, as `PointerHover`'s).
    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) { relay(event) }
    @objc(mouseExited:) func mouseExited(with event: NSEvent) {
        wasInBand = false
        guard let parent = panel?.parent else { return }
        Self.refresh(parent)
    }
    @objc(mouseMoved:) func mouseMoved(with event: NSEvent) { relay(event) }

    private func relay(_ event: NSEvent) {
        guard let panel, let parent = panel.parent, !panel.ignoresMouseEvents else { return }
        let inBand = panel.passesPointer(atScreen: panel.convertPoint(toScreen: event.locationInWindow))
        // A move inside the card covers the same views as the last one: nothing to recompute.
        guard inBand || wasInBand else { return }
        wasInBand = inBand
        Self.refresh(parent)
    }

    /// The parent's chrome hover (`PointerHover`) and every other hover of the window that follows the
    /// pointer on its own (the layout's dividers, `PointerBandFollower`).
    private static func refresh(_ parent: NSWindow) {
        PointerHover.refresh(in: parent)
        PointerTopWindow.pointerMovedInBand(over: parent)
    }
}
