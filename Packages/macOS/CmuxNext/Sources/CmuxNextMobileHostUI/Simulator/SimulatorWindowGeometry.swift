public import CoreGraphics

/// Where a simulator's screen is inside its Simulator window and how phone
/// touches map onto it (c14-web.md 6). The phone's coordinates are this
/// screen's points, which are the window's content points below the title
/// bar, so a touch maps to a global point by offset. Pure.
public struct SimulatorWindowGeometry: Hashable, Sendable {
    /// The window frame in global display points (top-left origin).
    public var windowFrame: CGRect
    /// The title bar above the device screen.
    public var titleBarHeight: CGFloat

    public init(windowFrame: CGRect, titleBarHeight: CGFloat = 28) {
        self.windowFrame = windowFrame
        self.titleBarHeight = titleBarHeight
    }

    /// The device screen in window points (top-left origin), what the capture crops.
    public var contentRect: CGRect {
        CGRect(x: 0, y: titleBarHeight, width: windowFrame.width, height: max(1, windowFrame.height - titleBarHeight))
    }

    /// A touch at (`x`, `y`) screen points as a global display point, clamped to the screen.
    public func globalPoint(x: Double, y: Double) -> CGPoint {
        let content = contentRect
        let clampedX = min(max(0, x), Double(content.width))
        let clampedY = min(max(0, y), Double(content.height))
        return CGPoint(x: windowFrame.minX + CGFloat(clampedX), y: windowFrame.minY + content.minY + CGFloat(clampedY))
    }
}
