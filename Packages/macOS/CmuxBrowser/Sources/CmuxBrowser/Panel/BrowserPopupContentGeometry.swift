public import AppKit

/// Pure placement geometry for a browser popup window's content rect.
///
/// Clamps a popup's requested size into `[min, visibleFrame]` and resolves its
/// origin, translating the web platform's top-anchored Y (distance from the
/// screen's top edge) into AppKit's bottom-up window origin. When no explicit
/// position is requested the popup is centered in the visible frame.
public struct BrowserPopupContentGeometry: Sendable, Equatable {
    /// Width used when the popup requests no width.
    public var defaultWidth: CGFloat
    /// Height used when the popup requests no height.
    public var defaultHeight: CGFloat
    /// Smallest width the popup may occupy.
    public var minWidth: CGFloat
    /// Smallest height the popup may occupy.
    public var minHeight: CGFloat

    /// Creates a geometry with the standard `WKWindowFeatures` fallback sizes.
    public init(
        defaultWidth: CGFloat = 800,
        defaultHeight: CGFloat = 600,
        minWidth: CGFloat = 200,
        minHeight: CGFloat = 150
    ) {
        self.defaultWidth = defaultWidth
        self.defaultHeight = defaultHeight
        self.minWidth = minWidth
        self.minHeight = minHeight
    }

    /// Computes the AppKit content rect for a popup within `visibleFrame`.
    ///
    /// - Parameters:
    ///   - requestedWidth: Popup-requested width, or `nil` to use `defaultWidth`.
    ///   - requestedHeight: Popup-requested height, or `nil` to use `defaultHeight`.
    ///   - requestedX: Popup-requested left edge in screen coordinates, or `nil`.
    ///   - requestedTopY: Popup-requested top edge as distance from the screen's
    ///     top edge, or `nil`. Both `requestedX` and `requestedTopY` must be
    ///     present to position the popup; otherwise it is centered.
    ///   - visibleFrame: The screen's visible frame to clamp into.
    public func contentRect(
        requestedWidth: CGFloat?,
        requestedHeight: CGFloat?,
        requestedX: CGFloat?,
        requestedTopY: CGFloat?,
        visibleFrame: NSRect
    ) -> NSRect {
        let clampedWidth = min(max(requestedWidth ?? defaultWidth, minWidth), visibleFrame.width)
        let clampedHeight = min(max(requestedHeight ?? defaultHeight, minHeight), visibleFrame.height)

        let x: CGFloat
        let y: CGFloat
        if let requestedX, let requestedTopY {
            x = max(visibleFrame.minX, min(requestedX, visibleFrame.maxX - clampedWidth))

            // Web content expresses popup Y as distance from the screen's top edge,
            // while AppKit window origins are bottom-up.
            let appKitY = visibleFrame.maxY - requestedTopY - clampedHeight
            y = max(visibleFrame.minY, min(appKitY, visibleFrame.maxY - clampedHeight))
        } else {
            x = visibleFrame.midX - clampedWidth / 2
            y = visibleFrame.midY - clampedHeight / 2
        }

        return NSRect(x: x, y: y, width: clampedWidth, height: clampedHeight)
    }
}
