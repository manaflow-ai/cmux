internal import CmuxFoundation

/// Validates persisted terminal font sizes and clamps values sent to Ghostty.
///
/// Ghostty accepts runtime point sizes from 1 through 255. Persisted values
/// are stored before global magnification, so the largest valid base value is
/// 510 points: 255 runtime points at the minimum supported 50% magnification.
public struct TerminalFontSizePolicy: Sendable {
    /// The minimum runtime point size accepted by Ghostty.
    public static let minimumRuntimePoints: Float32 = 1

    /// The maximum runtime point size accepted by Ghostty.
    public static let maximumRuntimePoints: Float32 = 255

    /// The largest persisted base size that can produce a valid Ghostty size.
    public static let maximumPersistedBasePoints: Float32 =
        maximumRuntimePoints * Float32(GlobalFontMagnification.defaultPercent)
            / Float32(GlobalFontMagnification.minimumPercent)

    /// Creates the fixed terminal font-size policy.
    public init() {}

    /// Returns whether a base size can be restored under supported magnification.
    ///
    /// - Parameter basePoints: The unscaled persisted font size in points.
    /// - Returns: True when the size is finite, positive, and no greater than
    ///   ``maximumPersistedBasePoints``.
    public func acceptsPersistedBasePoints(_ basePoints: Float32) -> Bool {
        basePoints.isFinite
            && basePoints > 0
            && basePoints <= Self.maximumPersistedBasePoints
    }

    /// Clamps a scaled point size to Ghostty's native runtime range.
    ///
    /// Non-finite positive values use the maximum; NaN and negative values use
    /// the minimum so this function always returns a native-safe value.
    ///
    /// - Parameter runtimePoints: The magnified size intended for Ghostty.
    /// - Returns: A finite value in the closed 1 through 255 point range.
    public func clampedRuntimePoints(_ runtimePoints: Float32) -> Float32 {
        guard runtimePoints.isFinite else {
            return runtimePoints == .infinity
                ? Self.maximumRuntimePoints
                : Self.minimumRuntimePoints
        }
        return min(
            Self.maximumRuntimePoints,
            max(Self.minimumRuntimePoints, runtimePoints)
        )
    }
}
