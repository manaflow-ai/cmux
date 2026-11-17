public import AppKit
public import CmuxNextDesign

/// The part of the Messages page that moves the window, as the native list's header did (a web view
/// never moves its window): a thin strip over the page's top edge, and the list header's band
/// (``band``, the page's report) except its controls (``controls``: search, the Unread toggle, the
/// chip), so a press on the band's empty space drags and a double-click runs the titlebar action,
/// while a press on a control reaches the page. It takes the app's one titlebar path
/// (``TitlebarDragPolicy``): it answers `.movesWindow` for its points, and the window's `sendEvent`
/// runs the drag or the double-click action (`WindowTitlebar.handleMouseDown`) once. Its own
/// mouse-down does nothing, so one press never moves the window twice.
public final class HomeWindowDragStrip: NSView, TitlebarPressDeciding {
    public static let height: CGFloat = 8

    /// The list header's band in the page's points from its top-left (zero: only the top edge drags).
    public private(set) var band: CGRect = .zero
    /// The header's controls in the same points: presses there go to the page.
    public private(set) var controls: [CGRect] = []

    override public var isFlipped: Bool { true }

    override public var mouseDownCanMoveWindow: Bool { true }

    /// The page reported its header band and controls (`cmux.home.messages.dragBand`).
    public func setBand(_ band: CGRect, controls: [CGRect]) {
        guard band != self.band || controls != self.controls else { return }
        (self.band, self.controls) = (band, controls)
        superview?.needsLayout = true
    }

    /// The strip's frame over a page of `bounds` (flipped, top-left origin): the top edge and the band.
    public func frame(in bounds: CGRect) -> CGRect {
        CGRect(x: 0, y: 0, width: bounds.width, height: max(Self.height, band.maxY))
    }

    /// Whether a press at `point` (the strip's own points) moves the window.
    public func drags(at point: CGPoint) -> Bool {
        if point.y >= 0, point.y < Self.height { return true }
        return band.contains(point) && !controls.contains { $0.contains(point) }
    }

    override public func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return drags(at: convert(point, from: superview)) ? hit : nil
    }

    /// The window's traffic lights (and a titlebar accessory on their line) over `page`'s top `band`, in
    /// its points from its top-left; nil when none lie there (the window's sidebar beside the page,
    /// full screen, no window).
    @MainActor public static func windowControls(over page: NSView, band: CGFloat) -> CGRect? {
        guard let window = page.window, let lights = WindowTitlebar.trafficLightsFrame(in: window) else { return nil }
        var controls = lights
        if let accessory = (window as? any TitlebarAccessoryHosting)?.titlebarAccessoryFrame, accessory.width > 0,
           abs(accessory.midY - lights.midY) < lights.height {
            controls = controls.union(accessory)
        }
        let local = page.convert(controls, from: nil)
        guard local.intersects(CGRect(x: 0, y: 0, width: page.bounds.width, height: band)) else { return nil }
        return local.integral
    }

    public func titlebarPress(atWindowPoint windowPoint: CGPoint) -> TitlebarPress { .movesWindow }

    /// The window's `sendEvent` handles the press (``TitlebarDragPolicy``); the page under the strip gets none.
    override public func mouseDown(with event: NSEvent) {}
}
