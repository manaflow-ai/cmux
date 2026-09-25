import Foundation

/// A width/height pair in canvas points.
public struct CanvasSize: Hashable, Codable, Sendable {
    /// Width in canvas points. Never negative for sizes produced by ``CanvasRect``.
    public var width: Double
    /// Height in canvas points. Never negative for sizes produced by ``CanvasRect``.
    public var height: Double

    /// The zero size.
    public static let zero = CanvasSize(width: 0, height: 0)

    /// Creates a size.
    ///
    /// - Parameters:
    ///   - width: Width in canvas points.
    ///   - height: Height in canvas points.
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}
