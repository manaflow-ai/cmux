public import CoreGraphics

/// Where a phone screen is drawn inside a tab (aspect fit, centered) and how
/// a point in the tab's AppKit coordinates (bottom-left origin) maps onto it.
public struct PhoneScreenMapping: Sendable, Hashable {
    /// The phone screen in points.
    public let screen: CGSize
    /// The view the screen is drawn into.
    public let view: CGSize

    public init(screen: CGSize, view: CGSize) {
        self.screen = screen
        self.view = view
    }

    /// The rectangle the screen fills inside the view.
    public var drawnRect: CGRect {
        guard screen.width > 0, screen.height > 0, view.width > 0, view.height > 0 else { return .zero }
        let scale = min(view.width / screen.width, view.height / screen.height)
        let size = CGSize(width: screen.width * scale, height: screen.height * scale)
        return CGRect(x: (view.width - size.width) / 2, y: (view.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// `viewPoint` as 0...1 screen coordinates with a top-left origin; nil outside the screen.
    public func normalized(viewPoint: CGPoint) -> CGPoint? {
        let rect = drawnRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        let x = (viewPoint.x - rect.minX) / rect.width
        let y = (rect.maxY - viewPoint.y) / rect.height
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// `viewPoint` in phone points (what ``PhoneInput/tap(_:)`` takes); nil outside the screen.
    public func devicePoint(viewPoint: CGPoint) -> PhonePoint? {
        normalized(viewPoint: viewPoint).map { PhonePoint(x: $0.x * screen.width, y: $0.y * screen.height) }
    }
}
