import Foundation

/// A spatial direction on the canvas, used for directional focus movement.
public enum CanvasDirection: String, Hashable, Codable, Sendable, CaseIterable {
    /// Toward smaller x.
    case left
    /// Toward larger x.
    case right
    /// Toward smaller y (the canvas space is y-down).
    case up
    /// Toward larger y.
    case down
}
