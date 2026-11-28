import CoreGraphics

/// Projection from canvas coordinates into minimap drawing coordinates.
struct CanvasMinimapProjection: Equatable {
    let scale: CGFloat
    let origin: CGPoint
}
