public import CoreGraphics

/// Where a phone screen is drawn inside a tab (aspect fit, centered) and how
/// a point in the tab's AppKit coordinates (bottom-left origin) maps onto it.
/// The geometry is `cmux-phone-core`'s (ops `drawn_rect`, `normalized_view_point`, `device_point`).
public struct PhoneScreenMapping: Sendable, Hashable {
    /// The phone screen in points.
    public let screen: CGSize
    /// The view the screen is drawn into.
    public let view: CGSize

    public init(screen: CGSize, view: CGSize) {
        self.screen = screen
        self.view = view
    }

    private var sizes: [String: Any] {
        ["screen": [Double(screen.width), Double(screen.height)], "view": [Double(view.width), Double(view.height)]]
    }

    /// The rectangle the screen fills inside the view.
    public var drawnRect: CGRect {
        guard let rect = try? PhoneRules.decode(PhoneRect.self, "rect", "drawn_rect", sizes, what: "the screen rectangle") else {
            return .zero
        }
        return CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    /// `viewPoint` as 0...1 screen coordinates with a top-left origin; nil outside the screen.
    public func normalized(viewPoint: CGPoint) -> CGPoint? {
        point("normalized_view_point", viewPoint).map { CGPoint(x: $0[0], y: $0[1]) }
    }

    /// `viewPoint` in phone points (what ``PhoneInput/tap(_:)`` takes); nil outside the screen.
    public func devicePoint(viewPoint: CGPoint) -> PhonePoint? {
        point("device_point", viewPoint).map { PhonePoint(x: $0[0], y: $0[1]) }
    }

    private func point(_ op: String, _ viewPoint: CGPoint) -> [Double]? {
        var fields = sizes
        fields["point"] = [Double(viewPoint.x), Double(viewPoint.y)]
        guard let point = try? PhoneRules.decode([Double]?.self, "point", op, fields, what: "the screen point"),
              point.count == 2 else { return nil }
        return point
    }
}
