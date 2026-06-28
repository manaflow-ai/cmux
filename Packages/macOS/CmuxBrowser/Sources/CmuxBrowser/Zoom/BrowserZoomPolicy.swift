public import CoreGraphics

/// The page-zoom bounds and step used by a browser panel.
///
/// The policy clamps any requested zoom into `[minimum, maximum]` and produces the next zoom
/// factor one ``step`` above or below a current value (without clamping; callers clamp on apply).
/// Construct one with the defaults (0.25…5.0, step 0.1) or override the bounds for testing.
public struct BrowserZoomPolicy: Sendable, Equatable {
    /// The smallest allowed page-zoom factor.
    public let minimum: CGFloat
    /// The largest allowed page-zoom factor.
    public let maximum: CGFloat
    /// The increment applied by ``zoomedIn(from:)`` / ``zoomedOut(from:)``.
    public let step: CGFloat

    /// Creates a zoom policy.
    /// - Parameters:
    ///   - minimum: The smallest allowed factor. Defaults to `0.25`.
    ///   - maximum: The largest allowed factor. Defaults to `5.0`.
    ///   - step: The per-keystroke increment. Defaults to `0.1`.
    public init(minimum: CGFloat = 0.25, maximum: CGFloat = 5.0, step: CGFloat = 0.1) {
        self.minimum = minimum
        self.maximum = maximum
        self.step = step
    }

    /// Clamps `value` into `[minimum, maximum]`.
    public func clamp(_ value: CGFloat) -> CGFloat {
        max(minimum, min(maximum, value))
    }

    /// The zoom factor one ``step`` above `current` (unclamped).
    public func zoomedIn(from current: CGFloat) -> CGFloat {
        current + step
    }

    /// The zoom factor one ``step`` below `current` (unclamped).
    public func zoomedOut(from current: CGFloat) -> CGFloat {
        current - step
    }
}
