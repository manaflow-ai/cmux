public import CoreGraphics

/// One floating pane of a screen: a pane the tiled layout leaves out, shown
/// above the tiled panes in a frame of its own (daemon `Screen.floating`,
/// `floating-panes-v1`).
public nonisolated struct LayoutFloatingPane: Hashable, Sendable {
    public var pane: PaneID
    /// The frame as fractions of the screen's pane area: a rect inside the
    /// unit square, with its origin at the top left.
    public var frame: CGRect

    public init(pane: PaneID, frame: CGRect) {
        self.pane = pane
        self.frame = frame
    }

    /// The smallest width and height of a floating pane, as a fraction of the pane area (the daemon's rule).
    public static let minimumExtent: CGFloat = 0.15

    /// `frame` moved and resized into the unit square, not smaller than ``minimumExtent`` (the daemon's rule: the
    /// size first, then the corner).
    public static func clamped(_ frame: CGRect) -> CGRect {
        let width = min(max(frame.width, minimumExtent), 1), height = min(max(frame.height, minimumExtent), 1)
        return CGRect(x: min(max(frame.minX, 0), 1 - width), y: min(max(frame.minY, 0), 1 - height), width: width, height: height)
    }

    /// The frame in a pane area of `size` (view coordinates), each edge on the pixel grid of `scale`.
    public func rect(in size: CGSize, scale: CGFloat) -> CGRect {
        func snap(_ value: CGFloat) -> CGFloat { scale > 0 ? (value * scale).rounded() / scale : value }
        let minX = snap(frame.minX * size.width), minY = snap(frame.minY * size.height)
        let maxX = snap(frame.maxX * size.width), maxY = snap(frame.maxY * size.height)
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    /// The height of the bar at a card's top that a pointer moves the pane by, and the width of the rim on the
    /// card's other sides that a pointer resizes it by.
    public static let barHeight: CGFloat = 14, rimWidth: CGFloat = 5

    /// The pane's frame inside its card: below the bar and inside the rim.
    public static func paneRect(inCard card: CGRect) -> CGRect {
        CGRect(x: card.minX + rimWidth, y: card.minY + barHeight, width: max(0, card.width - rimWidth * 2),
               height: max(0, card.height - barHeight - rimWidth))
    }

    /// The card that holds a pane at `pane`: the inverse of ``paneRect(inCard:)``.
    public static func cardRect(aroundPane pane: CGRect) -> CGRect {
        CGRect(x: pane.minX - rimWidth, y: pane.minY - barHeight, width: pane.width + rimWidth * 2, height: pane.height + barHeight + rimWidth)
    }

    /// The fractions of a pane area of `size` that `rect` (view coordinates) covers.
    public static func fractions(of rect: CGRect, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(x: rect.minX / size.width, y: rect.minY / size.height, width: rect.width / size.width, height: rect.height / size.height)
    }

    /// The intent that brings `pane` to the front when it gets the focus: one `raiseFloatingPane`, which names no
    /// frame (the frame that this model has can be older than the daemon's). Nil for a tiled pane, for the front
    /// pane and for a focus that a scroll moved.
    static func raise(_ pane: PaneID, in floating: [LayoutFloatingPane], source: ColumnFocusSource) -> LayoutIntent? {
        guard source != .scroll, floating.last?.pane != pane, floating.contains(where: { $0.pane == pane }) else { return nil }
        return .raiseFloatingPane(pane)
    }
}
