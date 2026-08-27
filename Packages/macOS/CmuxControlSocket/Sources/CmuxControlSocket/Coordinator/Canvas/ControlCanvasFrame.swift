public import Foundation

/// A pane frame in canvas coordinates (top-left origin, y grows downward),
/// crossing the canvas-domain seam in both directions.
public struct ControlCanvasFrame: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}
