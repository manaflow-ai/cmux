import CoreGraphics

/// Pure height policy for the growing composer text view. The text view grows
/// with its content (scrolling disabled so it has an intrinsic size), clamps to
/// a min/max band, and only enables scrolling once it would exceed the cap.
/// Kept free of UIKit so it unit-tests on the host.
public enum GrowingTextHeightSolver {
    public struct Result: Equatable, Sendable {
        /// The clamped height to apply to the height constraint.
        public let height: CGFloat
        /// Whether scrolling should be enabled (content exceeds the cap).
        public let scrollEnabled: Bool
    }

    /// - Parameters:
    ///   - fittingHeight: `sizeThatFits` height for the current text at the
    ///     current width, with scrolling disabled.
    ///   - minHeight: One-line floor.
    ///   - maxHeight: Cap beyond which the view scrolls instead of growing.
    public static func solve(
        fittingHeight: CGFloat,
        minHeight: CGFloat,
        maxHeight: CGFloat
    ) -> Result {
        let clamped = min(max(fittingHeight, minHeight), maxHeight)
        return Result(height: clamped, scrollEnabled: fittingHeight > maxHeight + 0.5)
    }
}
