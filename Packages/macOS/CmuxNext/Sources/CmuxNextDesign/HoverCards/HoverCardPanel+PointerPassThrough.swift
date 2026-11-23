import AppKit

/// Hover through the clear band around a card: only the drawn card keeps the pointer. The band
/// tells the parent window's hover the pointer moved, since the parent's own tracking areas hear
/// nothing while this window covers them.
extension HoverCardPanel: PointerPassThroughWindow {
    func passesPointer(atScreen point: CGPoint) -> Bool {
        !isShowingCard || !presentedCardFrame.contains(point)
    }

    /// The pointer entered, moved in or left this window: the parent's hover reads it again.
    func pointerMovedInBand() {
        PointerHover.refresh(in: parent)
    }
}

/// The tracking area owner of a hover card's window (``HoverCardPanel/pointerMovedInBand()``).
@MainActor
final class HoverCardBandTracker: NSObject {
    weak var panel: HoverCardPanel?

    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) { panel?.pointerMovedInBand() }
    @objc(mouseMoved:) func mouseMoved(with event: NSEvent) { panel?.pointerMovedInBand() }
    @objc(mouseExited:) func mouseExited(with event: NSEvent) { panel?.pointerMovedInBand() }
}
