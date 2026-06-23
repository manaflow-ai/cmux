public import AppKit

/// Computes the on-screen content rect for a scripted `window.open()` browser
/// popup panel from the requested geometry in `WKWindowFeatures`.
///
/// Holds the requested width/height/x/topY plus the default and minimum
/// dimensions as inputs; `contentRect(in:)` clamps them against a screen's
/// visible frame. Web content expresses the popup Y as distance from the
/// screen's top edge, while AppKit window origins are bottom-up, so the layout
/// flips the Y axis when an explicit position is requested. When no position is
/// requested the popup is centered in the visible frame.
public struct BrowserPopupContentLayout: Sendable {
    /// Requested popup width from `WKWindowFeatures`, or `nil` to use `defaultWidth`.
    public var requestedWidth: CGFloat?
    /// Requested popup height from `WKWindowFeatures`, or `nil` to use `defaultHeight`.
    public var requestedHeight: CGFloat?
    /// Requested popup X (left edge) from `WKWindowFeatures`, or `nil` to center.
    public var requestedX: CGFloat?
    /// Requested popup Y measured from the screen's top edge, or `nil` to center.
    public var requestedTopY: CGFloat?
    /// Fallback width when `requestedWidth` is `nil`.
    public var defaultWidth: CGFloat
    /// Fallback height when `requestedHeight` is `nil`.
    public var defaultHeight: CGFloat
    /// Lower bound on the resolved width.
    public var minWidth: CGFloat
    /// Lower bound on the resolved height.
    public var minHeight: CGFloat

    /// Creates a layout from the requested geometry and the default/minimum bounds.
    public init(
        requestedWidth: CGFloat?,
        requestedHeight: CGFloat?,
        requestedX: CGFloat?,
        requestedTopY: CGFloat?,
        defaultWidth: CGFloat = 800,
        defaultHeight: CGFloat = 600,
        minWidth: CGFloat = 200,
        minHeight: CGFloat = 150
    ) {
        self.requestedWidth = requestedWidth
        self.requestedHeight = requestedHeight
        self.requestedX = requestedX
        self.requestedTopY = requestedTopY
        self.defaultWidth = defaultWidth
        self.defaultHeight = defaultHeight
        self.minWidth = minWidth
        self.minHeight = minHeight
    }

    /// Resolves the popup content rect clamped to `visibleFrame`, flipping the
    /// requested top-down Y into AppKit's bottom-up origin, or centering when no
    /// explicit position was requested.
    public func contentRect(in visibleFrame: NSRect) -> NSRect {
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
