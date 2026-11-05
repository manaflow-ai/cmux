public import CoreGraphics

extension SurfaceRole {
    /// The role's corner radius: its level (``cornerDepth``) of the one concentric corner rule
    /// (`Metrics.corners`, `layout.paneCornerRadius` and `layout.cornerPadding`).
    @MainActor public var cornerRadius: CGFloat { Metrics.corners.radius(depth: cornerDepth) }
}
