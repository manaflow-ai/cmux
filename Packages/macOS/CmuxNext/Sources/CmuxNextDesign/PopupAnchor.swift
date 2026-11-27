public import AppKit

/// Where a popover or menu opened from a control goes: just under the control, lined up with
/// one of its edges.
///
/// A popup opened from a button opens at that button, never at the edge of the row or panel
/// the button sits in (Lawrence 2026-10-19: the group header's more button opened its editor
/// at the sidebar's leading edge, far from the button in a wide sidebar). A trailing control
/// (a more button at the end of a row) takes ``Edge/trailing``; a name or a pointer takes
/// ``Edge/leading``. A popup with no room below opens above the control, and one that would
/// leave the screen slides back onto it.
///
/// ```swift
/// let anchor = PopupAnchor(rect: buttonOnScreen, edge: .trailing)
/// let card = anchor.cardFrame(size: size, visible: screen.visibleFrame)
/// ```
public struct PopupAnchor: Sendable, Equatable {
    /// The control edge the popup lines up with.
    public enum Edge: Sendable, Equatable {
        /// The popup's leading edge on the control's leading edge (it extends toward the trailing side).
        case leading
        /// The popup's trailing edge on the control's trailing edge (it extends toward the leading side).
        case trailing
    }

    /// The control's rect, in the coordinates the caller places the popup in.
    public let rect: CGRect
    /// The control edge the popup lines up with.
    public let edge: Edge
    /// The space between the control and the popup.
    public let gap: CGFloat
    /// The least space a card keeps from the visible frame's edges.
    public let margin: CGFloat

    /// An anchor at `rect`.
    /// - Parameters:
    ///   - rect: The control's rect.
    ///   - edge: The control edge the popup lines up with.
    ///   - gap: The space between the control and the popup; `Metrics.space1` by default, the
    ///     gap every sidebar popup kept.
    ///   - margin: The least space a card keeps from the screen's edges; `Metrics.space2` by default.
    public init(rect: CGRect, edge: Edge, gap: CGFloat = Metrics.space1, margin: CGFloat = Metrics.space2) {
        self.rect = rect
        self.edge = edge
        self.gap = gap
        self.margin = margin
    }

    /// An anchor at a point (a right-click): the popup opens with its leading edge there.
    /// - Parameter point: The point, in the coordinates the caller places the popup in.
    public init(point: CGPoint) {
        self.init(rect: CGRect(origin: point, size: .zero), edge: .leading, gap: 0)
    }

    /// The frame of a card of `size` under the control, in screen coordinates (y up).
    ///
    /// The card lines up with ``edge``; with no room under the control it opens above it. When
    /// the card's side leaves no room, it lines up with the control's other edge, and it slides
    /// sideways, then up or down, to stay inside the area it keeps to: the window on each axis
    /// the card fits in (sidebar sweep 2026-10-21: an editor wider than the sidebar hung past
    /// the window's edge), else the screen.
    /// - Parameters:
    ///   - size: The card's size.
    ///   - visible: The screen's visible frame; nil (no screen, as on a machine with no display)
    ///     keeps the card to `window` alone, and with no window either places it without clamping.
    ///   - window: The frame of the window the card opens over, in the same coordinates.
    /// - Returns: The card's frame.
    public func cardFrame(size: CGSize, visible: CGRect?, window: CGRect? = nil) -> CGRect {
        var origin = CGPoint(x: edge == .leading ? rect.minX : rect.maxX - size.width, y: rect.minY - gap - size.height)
        guard let area = area(for: size, visible: visible, window: window) else { return CGRect(origin: origin, size: size) }
        if origin.y < area.minY + margin, rect.maxY + gap + size.height <= area.maxY - margin {
            origin.y = rect.maxY + gap
        }
        origin.y = min(max(origin.y, area.minY + margin), area.maxY - size.height - margin)
        let lowest = area.minX + margin, highest = area.maxX - size.width - margin
        let other = edge == .leading ? rect.maxX - size.width : rect.minX
        if !(lowest...max(lowest, highest)).contains(origin.x), (lowest...max(lowest, highest)).contains(other) {
            origin.x = other
        }
        origin.x = min(max(origin.x, lowest), highest)
        return CGRect(origin: origin, size: size)
    }

    /// Where a card of `size` keeps to: on each axis the window's part of the screen when the
    /// card fits in it with its margins, else the screen (with no screen, no bound on that
    /// axis); nil with neither a screen nor a window.
    private func area(for size: CGSize, visible: CGRect?, window: CGRect?) -> CGRect? {
        guard visible != nil || window != nil else { return nil }
        let visible = visible ?? .infinite
        guard let window else { return visible }
        let inside = window.intersection(visible)
        guard !inside.isNull else { return visible }
        let fitsX = size.width + 2 * margin <= inside.width, fitsY = size.height + 2 * margin <= inside.height
        return CGRect(x: fitsX ? inside.minX : visible.minX, y: fitsY ? inside.minY : visible.minY,
                      width: fitsX ? inside.width : visible.width, height: fitsY ? inside.height : visible.height)
    }

    /// The point `NSMenu.popUp(positioning:at:in:)` takes to open a menu of `size` under the
    /// control, lined up with ``edge``, in the coordinates of the view the menu opens in.
    ///
    /// The menu itself moves back onto the screen and opens above at the screen's bottom.
    /// - Parameters:
    ///   - size: The menu's size (`NSMenu.size`).
    ///   - flipped: Whether the view's y axis points down (`NSView.isFlipped`).
    /// - Returns: The menu's top-leading corner.
    public func menuOrigin(size: CGSize, flipped: Bool) -> NSPoint {
        let x = edge == .leading ? rect.minX : rect.maxX - size.width
        return NSPoint(x: x, y: flipped ? rect.maxY + gap : rect.minY - gap)
    }
}
