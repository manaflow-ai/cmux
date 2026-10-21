public import CoreGraphics

/// The rect a person drags over a page for Screenshot Section, and the crop
/// of the page snapshot it selects.
///
/// Points are in the page view's coordinates (`bounds`, origin at the bottom
/// left, as an unflipped `NSView`). A page snapshot has its origin at the top
/// left and may have more pixels than the view has points (a Retina page),
/// so ``pixelRect(imageWidth:imageHeight:)`` scales each axis by the
/// snapshot's size over `bounds`.
///
/// ```swift
/// var selection = BrowserSectionSelection(bounds: pageView.bounds)
/// selection.begin(at: down)
/// selection.drag(to: up)
/// let section = try await selection.capture(from: tab)
/// ```
public nonisolated struct BrowserSectionSelection: Equatable, Sendable {
    /// The smallest width and height, in points, that count as a selection;
    /// a click or a shorter drag selects nothing.
    public static let minimumSide: CGFloat = 4

    /// The page view's bounds; the selection never leaves them.
    public let bounds: CGRect
    private var anchor: CGPoint?
    private var current: CGPoint?

    /// A selection over a page view with `bounds`, before any drag.
    /// - Parameter bounds: The page view's bounds, in its own coordinates.
    public init(bounds: CGRect) {
        self.bounds = bounds
    }

    /// Starts a drag at `point` (the mouse-down), dropping any earlier one.
    public mutating func begin(at point: CGPoint) {
        anchor = clamp(point)
        current = anchor
    }

    /// Moves the drag's free corner to `point`, clamped to ``bounds``.
    public mutating func drag(to point: CGPoint) {
        guard anchor != nil else { return }
        current = clamp(point)
    }

    /// The selected rect in view points, or nil before a drag or while either
    /// side is shorter than ``minimumSide``.
    public var rect: CGRect? {
        guard let anchor, let current else { return nil }
        let rect = CGRect(x: min(anchor.x, current.x), y: min(anchor.y, current.y),
                          width: abs(current.x - anchor.x), height: abs(current.y - anchor.y))
        guard rect.width >= Self.minimumSide, rect.height >= Self.minimumSide else { return nil }
        return rect
    }

    /// The selection in the pixels of a snapshot `imageWidth` by
    /// `imageHeight` of the whole page view, origin at the top left, rounded
    /// out to whole pixels and kept inside the image.
    /// - Returns: Nil without a selection or with empty bounds.
    public func pixelRect(imageWidth: Int, imageHeight: Int) -> CGRect? {
        guard let rect, bounds.width > 0, bounds.height > 0 else { return nil }
        let scaleX = CGFloat(imageWidth) / bounds.width, scaleY = CGFloat(imageHeight) / bounds.height
        let pixels = CGRect(x: (rect.minX - bounds.minX) * scaleX, y: (bounds.maxY - rect.maxY) * scaleY,
                            width: rect.width * scaleX, height: rect.height * scaleY).integral
        let inside = pixels.intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
        return inside.isEmpty ? nil : inside
    }

    /// `image` (a snapshot of the whole page view) cropped to the selection.
    /// - Returns: Nil without a selection.
    public func crop(_ image: CGImage) -> CGImage? {
        guard let pixels = pixelRect(imageWidth: image.width, imageHeight: image.height) else { return nil }
        return image.cropping(to: pixels)
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }
}
