/// The pane edges a canvas drag moves. Empty moves the whole pane; `top` is
/// the edge at the smaller y (canvas coordinates are flipped, top-left origin).
public nonisolated struct CanvasResizeEdges: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    /// Edges from their bits.
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// The edge at the smaller x.
    public static let left = CanvasResizeEdges(rawValue: 1 << 0)
    /// The edge at the larger x.
    public static let right = CanvasResizeEdges(rawValue: 1 << 1)
    /// The edge at the smaller y.
    public static let top = CanvasResizeEdges(rawValue: 1 << 2)
    /// The edge at the larger y.
    public static let bottom = CanvasResizeEdges(rawValue: 1 << 3)
}
