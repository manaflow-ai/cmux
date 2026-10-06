public import AppKit

/// Shared local-coordinate anchoring for transient menus and popovers.
///
/// AppKit's menu and popover presenters do their own screen-edge flipping. The
/// important part we control is the source rect and point: derive it from the
/// trigger's bounds, in that trigger's coordinate space, so titlebar/content
/// scale and flipped views cannot introduce an offset.
public enum CmuxPopoverAnchor {
    public static let defaultGap: CGFloat = 6

    /// The point at the trigger's leading edge for an `NSMenu.popUp` call.
    /// AppKit flips the menu when the preferred side has no room.
    public static func menuPoint(in view: NSView, gap: CGFloat = defaultGap,
                                 edge: NSRectEdge = .maxY) -> NSPoint {
        let bounds = view.bounds
        let x = bounds.minX
        let y: CGFloat
        switch edge {
        case .maxY:
            y = view.isFlipped ? bounds.maxY + gap : bounds.minY - gap
        case .minY:
            y = view.isFlipped ? bounds.minY - gap : bounds.maxY + gap
        case .minX:
            y = bounds.maxY
        case .maxX:
            y = bounds.maxY
        @unknown default:
            y = view.isFlipped ? bounds.maxY + gap : bounds.minY - gap
        }
        return NSPoint(x: x, y: y)
    }

    /// The same point converted into the coordinate space used by the menu
    /// presenter when the trigger is a descendant of that view.
    public static func menuPoint(for trigger: NSView, in presenter: NSView,
                                 gap: CGFloat = defaultGap, edge: NSRectEdge = .maxY) -> NSPoint {
        let local = menuPoint(in: trigger, gap: gap, edge: edge)
        return presenter.convert(local, from: trigger)
    }

    /// The complete trigger rect for `NSPopover.show(relativeTo:of:)`.
    public static func rect(in view: NSView) -> NSRect { view.bounds }
}
