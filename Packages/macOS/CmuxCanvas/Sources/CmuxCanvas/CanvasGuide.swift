import Foundation

/// An alignment guide line produced while a snap is active.
///
/// The rendering layer draws guides during drag and resize gestures so the
/// user can see which neighbor edge a pane snapped to.
public struct CanvasGuide: Hashable, Sendable {
    /// The orientation of a guide line.
    public enum Axis: Hashable, Sendable {
        /// A vertical line at a fixed x coordinate.
        case vertical
        /// A horizontal line at a fixed y coordinate.
        case horizontal
    }

    /// The guide orientation.
    public let axis: Axis
    /// The fixed coordinate: x for vertical guides, y for horizontal guides.
    public let position: Double
    /// The extent of the line along its own axis (y-range for vertical
    /// guides, x-range for horizontal guides), covering both snapped rects.
    public let span: ClosedRange<Double>

    /// Creates a guide.
    ///
    /// - Parameters:
    ///   - axis: The guide orientation.
    ///   - position: The fixed coordinate of the line.
    ///   - span: The extent of the line along its own axis.
    public init(axis: Axis, position: Double, span: ClosedRange<Double>) {
        self.axis = axis
        self.position = position
        self.span = span
    }
}
