public import AppKit
public import CmuxNextDesign

/// Screen hit-testing reports hover transitions with the original event, which may be a mouse move.
/// Keep them separate from AppKit's tracking-area callbacks and their enter/exit-only metadata.
extension TabStripView: PanePointerFollowing {
    public func panePointerCursor(at point: NSPoint) -> NSCursor? { nil }
    public func panePointerEntered(with event: NSEvent) { pointerEntered(at: event.locationInWindow) }
    public func panePointerMoved(with event: NSEvent) { mouseMoved(with: event) }
    public func panePointerExited(with event: NSEvent) { pointerExited(at: event.locationInWindow) }

    func pointerEntered(at windowPoint: NSPoint) {
        buttonReveal.pointerInStrip = true
        closingWatch.pointerReturned()
        updateHover(at: convert(windowPoint, from: nil), moved: true)
    }

    func pointerExited(at windowPoint: NSPoint) {
        pointerLeft()
        hoverCards.pointerMoved(to: window.map { $0.convertPoint(toScreen: windowPoint) })
    }
}
