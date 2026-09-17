#if canImport(UIKit)
import CoreGraphics

/// Exact layer and viewport geometry owned by one verified replay submission.
/// Arrays hold the sixteen CATransform3D scalars without making QuartzCore
/// reference types part of the cross-queue fence value.
nonisolated struct VerifiedReplayPresentationGeometry: Equatable, Sendable {
    let rendererFrame: CGRect
    let rendererBounds: CGRect
    let rendererPosition: CGPoint
    let rendererAnchorPoint: CGPoint
    let rendererContentsScale: CGFloat
    let rendererTransform: [CGFloat]
    let hostBounds: CGRect
    let hostPosition: CGPoint
    let hostAnchorPoint: CGPoint
    let hostTransform: [CGFloat]
    let viewportRect: CGRect
}
#endif
