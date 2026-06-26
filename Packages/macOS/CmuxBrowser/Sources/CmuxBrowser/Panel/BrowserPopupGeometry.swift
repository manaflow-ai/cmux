public import AppKit

/// The requested geometry for a scripted browser popup window (`window.open`),
/// resolved into an AppKit content rect that is clamped to the target screen's
/// visible frame.
///
/// Web content supplies popup dimensions and an optional top-left origin, where
/// the Y coordinate is measured as distance from the screen's top edge. AppKit
/// window origins are bottom-up, so ``contentRect`` clamps the size to the
/// visible frame, converts the top-down Y to a bottom-up origin, and falls back
/// to centering the popup when no origin is requested.
public struct BrowserPopupGeometry: Equatable, Sendable {
    /// Requested content width, or `nil` to use ``defaultWidth``.
    public var requestedWidth: CGFloat?

    /// Requested content height, or `nil` to use ``defaultHeight``.
    public var requestedHeight: CGFloat?

    /// Requested left origin (screen coordinates), or `nil` to center.
    public var requestedX: CGFloat?

    /// Requested top origin measured from the screen's top edge, or `nil` to
    /// center. Only honored when ``requestedX`` is also present.
    public var requestedTopY: CGFloat?

    /// The target screen's visible frame, used to clamp the popup on-screen.
    public var visibleFrame: NSRect

    /// Width used when ``requestedWidth`` is `nil`.
    public var defaultWidth: CGFloat

    /// Height used when ``requestedHeight`` is `nil`.
    public var defaultHeight: CGFloat

    /// Minimum allowed content width.
    public var minWidth: CGFloat

    /// Minimum allowed content height.
    public var minHeight: CGFloat

    /// Creates a popup geometry request.
    /// - Parameters:
    ///   - requestedWidth: requested content width, or `nil` for ``defaultWidth``.
    ///   - requestedHeight: requested content height, or `nil` for ``defaultHeight``.
    ///   - requestedX: requested left origin in screen coordinates, or `nil` to center.
    ///   - requestedTopY: requested top origin from the screen's top edge, or `nil` to center.
    ///   - visibleFrame: the target screen's visible frame for clamping.
    ///   - defaultWidth: width used when `requestedWidth` is `nil`.
    ///   - defaultHeight: height used when `requestedHeight` is `nil`.
    ///   - minWidth: minimum allowed content width.
    ///   - minHeight: minimum allowed content height.
    public init(
        requestedWidth: CGFloat?,
        requestedHeight: CGFloat?,
        requestedX: CGFloat?,
        requestedTopY: CGFloat?,
        visibleFrame: NSRect,
        defaultWidth: CGFloat = 800,
        defaultHeight: CGFloat = 600,
        minWidth: CGFloat = 200,
        minHeight: CGFloat = 150
    ) {
        self.requestedWidth = requestedWidth
        self.requestedHeight = requestedHeight
        self.requestedX = requestedX
        self.requestedTopY = requestedTopY
        self.visibleFrame = visibleFrame
        self.defaultWidth = defaultWidth
        self.defaultHeight = defaultHeight
        self.minWidth = minWidth
        self.minHeight = minHeight
    }

    /// The popup's content rect, clamped to ``visibleFrame``.
    public var contentRect: NSRect {
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
