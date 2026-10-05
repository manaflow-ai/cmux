import Foundation

/// The texture treatment applied once to a backdrop image when it is loaded.
public nonisolated struct BackdropTexture: Hashable, Sendable {
    /// The selected texture algorithm.
    public let filter: BackdropTextureFilter
    /// The filter strength, from none to full effect.
    public let strength: Double

    /// The quiet default for authored artwork.
    public static let `default` = Self(filter: .orderedDither4x4, strength: 0.12)

    /// Creates a texture treatment, clamping invalid strength values safely.
    ///
    /// - Parameters:
    ///   - filter: The algorithm to apply.
    ///   - strength: The effect intensity in the inclusive range 0...1.
    public init(filter: BackdropTextureFilter, strength: Double) {
        self.filter = filter
        self.strength = strength.isFinite ? min(max(strength, 0), 1) : (strength.sign == .plus ? 1 : 0)
    }

    /// A stable cache component for one treatment.
    public var id: String { "\(filter.rawValue):\(String(format: "%.3f", strength))" }
}
