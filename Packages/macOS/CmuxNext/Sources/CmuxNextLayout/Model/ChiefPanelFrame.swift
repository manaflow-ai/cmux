public import CoreGraphics

/// Where the floating Chief sits in a window's content area, as fractions of that area (y runs down), so it keeps
/// its place when the window resizes. Pure value: ``ChiefPanel`` holds it and the window record persists it.
public nonisolated struct ChiefPanelFrame: Hashable, Sendable {
    /// The left edge, 0...1 of the content width.
    public var x: Double
    /// The top edge, 0...1 of the content height (y runs down).
    public var y: Double
    /// The width, a fraction of the content width.
    public var width: Double
    /// The height, a fraction of the content height.
    public var height: Double

    /// The first place: the right part of the content area, nearly full height, clear of the edges.
    public static let initial = ChiefPanelFrame(x: 0.6, y: 0.04, width: 0.37, height: 0.92)
    /// The smallest panel, in points: the Chief's header and message box still fit.
    public static let minimumSize = CGSize(width: 280, height: 220)

    /// - Parameters:
    ///   - x: The left edge, a fraction of the content width.
    ///   - y: The top edge, a fraction of the content height (y runs down).
    ///   - width: The width, a fraction of the content width.
    ///   - height: The height, a fraction of the content height.
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The panel's rect in a content area of `size` (y runs down): at least ``minimumSize`` (or the whole area when
    /// smaller), and always fully inside the area, so a window made smaller never leaves the panel off screen.
    /// `minimum` is a smaller floor for a style that rests smaller (``ChiefPanelStyle``).
    public func rect(in size: CGSize, minimum: CGSize = Self.minimumSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let w = min(size.width, max(minimum.width, width * size.width))
        let h = min(size.height, max(minimum.height, height * size.height))
        let left = min(max(0, x * size.width), size.width - w)
        let top = min(max(0, y * size.height), size.height - h)
        return CGRect(x: left.rounded(), y: top.rounded(), width: w.rounded(), height: h.rounded())
    }

    /// The frame that puts the panel at `rect` (y runs down) in a content area of `size`, after the same clamping
    /// ``rect(in:)`` does: what a drag or a resize stores.
    public static func fitting(_ rect: CGRect, in size: CGSize, minimum: CGSize = minimumSize) -> ChiefPanelFrame {
        guard size.width > 0, size.height > 0 else { return .initial }
        let w = min(size.width, max(minimum.width, rect.width))
        let h = min(size.height, max(minimum.height, rect.height))
        let left = min(max(0, rect.minX), size.width - w)
        let top = min(max(0, rect.minY), size.height - h)
        return ChiefPanelFrame(x: left / size.width, y: top / size.height, width: w / size.width, height: h / size.height)
    }
}
