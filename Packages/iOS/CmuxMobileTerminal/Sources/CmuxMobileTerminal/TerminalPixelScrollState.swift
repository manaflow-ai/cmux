import CoreGraphics

/// Reconciles a continuous UIKit offset with Ghostty's row-based viewport.
public nonisolated struct TerminalPixelScrollState: Equatable, Sendable {
    /// One sampled scroll position and the viewport work it produces.
    public struct Sample: Equatable, Sendable {
        /// The input offset clamped to the available scrollback range.
        public let effectiveOffsetY: CGFloat
        /// The nearest Ghostty row to place at the top of the viewport.
        public let targetViewportRow: UInt64
        /// The sub-row renderer translation required until that row is presented.
        public let presentationTranslationY: CGFloat
    }

    /// The latest clamped UIKit offset.
    public private(set) var effectiveOffsetY: CGFloat
    /// The exact row position most recently presented by Ghostty.
    public private(set) var authoritativeOffsetY: CGFloat

    /// Creates state aligned to the currently presented viewport.
    ///
    /// - Parameter initialOffsetY: The presented viewport position in points.
    public init(initialOffsetY: CGFloat) {
        effectiveOffsetY = initialOffsetY
        authoritativeOffsetY = initialOffsetY
    }

    /// Rebases fractional presentation after Ghostty presents an exact row.
    ///
    /// - Parameter offsetY: The newly presented row position in points.
    public mutating func updateAuthoritativeOffsetY(_ offsetY: CGFloat) {
        authoritativeOffsetY = offsetY
    }

    /// Samples a native scroll position without changing terminal row semantics.
    ///
    /// The returned translation includes UIKit rubber-banding and is capped at
    /// two rows while an asynchronous Ghostty row presentation catches up.
    ///
    /// - Parameters:
    ///   - rawOffsetY: The current, potentially rubber-banded UIKit offset.
    ///   - maximumOffsetY: The largest valid scrollback offset in points.
    ///   - cellHeight: One rendered terminal row in points.
    /// - Returns: The row request and renderer translation for this sample.
    public mutating func sample(
        rawOffsetY: CGFloat,
        maximumOffsetY: CGFloat,
        cellHeight: CGFloat
    ) -> Sample {
        let nextEffectiveOffsetY = min(max(rawOffsetY, 0), maximumOffsetY)
        effectiveOffsetY = nextEffectiveOffsetY
        let targetViewportRow = cellHeight > 0
            ? UInt64(max(0, (nextEffectiveOffsetY / cellHeight).rounded()))
            : 0
        let rubberBandTranslation = -(rawOffsetY - nextEffectiveOffsetY)
        let translationLimit = cellHeight * 2
        let fractionalTranslation = min(
            max(authoritativeOffsetY - nextEffectiveOffsetY, -translationLimit),
            translationLimit
        )
        return Sample(
            effectiveOffsetY: nextEffectiveOffsetY,
            targetViewportRow: targetViewportRow,
            presentationTranslationY: rubberBandTranslation + fractionalTranslation
        )
    }
}
