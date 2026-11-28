import Foundation

/// The set of pane edges being moved by a resize gesture.
///
/// A corner drag contains two edges (for example `[.right, .bottom]`); an
/// edge drag contains one.
public struct CanvasResizeEdges: OptionSet, Hashable, Sendable {
    /// The raw option bits.
    public let rawValue: Int

    /// Creates an edge set from raw option bits.
    ///
    /// - Parameter rawValue: The raw option bits.
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The left edge is moving.
    public static let left = CanvasResizeEdges(rawValue: 1 << 0)
    /// The right edge is moving.
    public static let right = CanvasResizeEdges(rawValue: 1 << 1)
    /// The top edge is moving (y-down space).
    public static let top = CanvasResizeEdges(rawValue: 1 << 2)
    /// The bottom edge is moving.
    public static let bottom = CanvasResizeEdges(rawValue: 1 << 3)
}
