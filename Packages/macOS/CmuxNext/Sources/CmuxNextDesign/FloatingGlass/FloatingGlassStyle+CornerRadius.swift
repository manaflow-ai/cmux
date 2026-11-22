public import CoreGraphics

extension FloatingGlassStyle {
    /// The continuous corner radius: the style's level (``cornerDepth``) of the one concentric
    /// corner rule (`Metrics.corners`).
    @MainActor public var cornerRadius: CGFloat { Metrics.corners.radius(depth: cornerDepth) }
}
