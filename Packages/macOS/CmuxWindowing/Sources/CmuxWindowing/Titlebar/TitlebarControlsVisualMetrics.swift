public import CoreGraphics

/// Vertical-lift positioning constant for the titlebar controls accessory.
///
/// A pure value type wrapping the single point offset the controls content is
/// lifted within its container. Exposed as a value (rather than a bare
/// constant) so the lift can be applied through ``liftedYOffset(_:)`` at the
/// app-side offset computations without those call sites re-deriving the math.
public struct TitlebarControlsVisualMetrics: Sendable {
    /// Points the controls content is lifted within its container.
    public let verticalLift: CGFloat

    /// Creates the metrics from the vertical lift, in points.
    public init(verticalLift: CGFloat) {
        self.verticalLift = verticalLift
    }

    /// The lift applied to the titlebar controls accessory.
    public static let standard = TitlebarControlsVisualMetrics(verticalLift: 0)

    /// Applies the vertical lift to a computed y-offset.
    public func liftedYOffset(_ yOffset: CGFloat) -> CGFloat {
        yOffset + verticalLift
    }
}
