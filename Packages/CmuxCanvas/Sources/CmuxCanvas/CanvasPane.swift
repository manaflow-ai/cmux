import Foundation

/// One pane on the canvas: an identifier plus its frame.
///
/// Z-order is not stored here; it is the pane's position inside
/// ``CanvasLayout/panes`` (back to front).
public struct CanvasPane: Hashable, Codable, Sendable, Identifiable {
    /// The pane identifier.
    public let id: CanvasPaneID
    /// The pane frame in canvas coordinates.
    public var frame: CanvasRect

    /// Creates a pane.
    ///
    /// - Parameters:
    ///   - id: The pane identifier.
    ///   - frame: The pane frame in canvas coordinates.
    public init(id: CanvasPaneID, frame: CanvasRect) {
        self.id = id
        self.frame = frame
    }
}
