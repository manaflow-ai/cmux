public import CoreGraphics

/// The drawn line and the hit area of one resize handle, centered on the gap the handle resizes.
///
/// Every pane resize handle (split dividers, column edges, dock edges, row edges) takes its hit
/// frame from here, so the line `DividerHandleView` draws, the area that takes the mouse and the
/// resize cursor share one center. The line starts on a device pixel, and the hit area grows by
/// the same whole number of device pixels on both sides of it, so the view's "line in the middle
/// of the bounds" lands on that line with no further rounding at any backing scale (u2345: a
/// half-point hit frame drew the line a pixel off at 1x; a dock's handle sat inside the dock).
///
/// ```swift
/// let band = DividerBand(axis: .horizontal, center: gap.midX, lineThickness: 2, hitThickness: 7,
///                        crossStart: 0, crossLength: 900, scale: 2)
/// handle.frame = band.hit
/// ```
public nonisolated struct DividerBand: Hashable, Sendable {
    /// The line the handle draws.
    public var line: CGRect
    /// The area that takes the mouse and shows the resize cursor; `line` is centered in it.
    public var hit: CGRect

    /// A band centered on `center`.
    ///
    /// - Parameter axis: `.horizontal` for a handle between side-by-side panes (a vertical line
    ///   dragged left and right), `.vertical` for one between stacked panes.
    /// - Parameter center: Middle of the gap along `axis`, in the caller's coordinates.
    /// - Parameter lineThickness: The drawn line's thickness (0 draws none; the hit area remains).
    /// - Parameter hitThickness: The smallest hit area across the line; rounded up to whole
    ///   device pixels on each side so it stays centered.
    /// - Parameter crossStart: Where the band starts along the other axis.
    /// - Parameter crossLength: The band's length along the other axis.
    /// - Parameter scale: Device pixels per point.
    public init(axis: SplitAxis, center: CGFloat, lineThickness: CGFloat, hitThickness: CGFloat,
                crossStart: CGFloat, crossLength: CGFloat, scale: CGFloat) {
        let thickness = max(0, lineThickness)
        let lineStart = SplitGeometry.roundToPixel(center - thickness / 2, scale: scale)
        let grow = SplitGeometry.ceilToPixel(max(0, hitThickness - thickness) / 2, scale: scale)
        func rect(start: CGFloat, extent: CGFloat) -> CGRect {
            axis == .horizontal
                ? CGRect(x: start, y: crossStart, width: extent, height: crossLength)
                : CGRect(x: crossStart, y: start, width: crossLength, height: extent)
        }
        line = rect(start: lineStart, extent: thickness)
        hit = rect(start: lineStart - grow, extent: thickness + grow * 2)
    }
}
