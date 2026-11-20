import AppKit
import CmuxNextDesign

/// A scroll on a divider's grab strip (in-tree pages, `InTreePages`).
///
/// The handle's hit area reaches a few points into the panes beside its line, so a scroll that starts on it, which the
/// layout leaves alone (a plain scroll over no pane), used to reach the handle and stop there: over a Chromium page the
/// strip did not scroll the page. With pages in the tree the handle is the only thing there, and it passes the scroll
/// to the pane on the pointer's side of its line, at the nearest point inside that pane, so the page, terminal or
/// WebKit view under the pointer's side scrolls as if the pointer were on it. With the mode off nothing changes.
extension DividerHandleView {
    override func scrollWheel(with event: NSEvent) {
        guard InTreePages.shared.isActive, let window, let target = Self.paneTarget(of: self, for: event, in: window),
              let forwarded = Self.event(event, relocatedTo: target.point, in: window) else {
            return super.scrollWheel(with: event)
        }
        target.view.scrollWheel(with: forwarded)
    }

    /// The point, in window coordinates, just past this handle's band on the side of the line where `point` (window
    /// coordinates) is: left or right of a vertical line (`axis` horizontal), above or below a horizontal one.
    nonisolated static func sidePoint(of point: NSPoint, bandInWindow band: NSRect, lineMid: CGFloat, axis: SplitAxis) -> NSPoint {
        switch axis {
        case .horizontal:
            NSPoint(x: point.x < lineMid ? band.minX - 1 : band.maxX + 1, y: min(max(point.y, band.minY), band.maxY))
        case .vertical:
            NSPoint(x: min(max(point.x, band.minX), band.maxX), y: point.y < lineMid ? band.minY - 1 : band.maxY + 1)
        }
    }

    /// The view the window's hit test gives at the side point of `handle` for `event`, and that point; nil when it is
    /// another divider or nothing (the window's edge).
    static func paneTarget(of handle: DividerHandleView, for event: NSEvent, in window: NSWindow) -> (view: NSView, point: NSPoint)? {
        guard let frameView = window.contentView?.superview else { return nil }
        let band = handle.convert(handle.bounds, to: nil)
        // The line runs down the middle of the band.
        let mid = handle.axis == .horizontal ? band.midX : band.midY
        let point = sidePoint(of: windowPoint(of: event, in: window), bandInWindow: band, lineMid: mid, axis: handle.axis)
        guard let hit = frameView.hitTest(frameView.convert(point, from: nil)), !(hit is DividerHandleView),
              !hit.isDescendant(of: handle) else { return nil }
        return (hit, point)
    }

    /// `event`'s pointer in `window`'s coordinates. An event with no window (one made from a `CGEvent`, which AppKit
    /// gives in screen coordinates) or of another window is converted through the screen.
    static func windowPoint(of event: NSEvent, in window: NSWindow) -> NSPoint {
        if event.window === window { return event.locationInWindow }
        let screen = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
        return window.convertPoint(fromScreen: screen)
    }

    /// `event` with its pointer at `windowPoint` of `window` (its deltas, phases and momentum kept); nil when it has no
    /// Core Graphics event to copy.
    static func event(_ event: NSEvent, relocatedTo windowPoint: NSPoint, in window: NSWindow) -> NSEvent? {
        guard let copy = event.cgEvent?.copy(), let primary = NSScreen.screens.first else { return nil }
        let screen = window.convertPoint(toScreen: windowPoint)
        copy.location = CGPoint(x: screen.x, y: primary.frame.maxY - screen.y)
        // The window under the pointer is the window the scroll goes to.
        copy.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        copy.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        return NSEvent(cgEvent: copy)
    }
}
