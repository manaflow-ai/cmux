import CoreGraphics

/// Pure viewport state that reconciles pixel offsets with Ghostty's row grid.
nonisolated struct NativeScrollState: Equatable, Sendable {
    /// One sampled scroll-view position and the work it produces.
    struct Sample: Equatable, Sendable {
        let effectiveOffsetY: CGFloat
        let targetViewportRow: UInt64
        let presentationTranslationY: CGFloat
    }

    private(set) var effectiveOffsetY: CGFloat
    private(set) var authoritativeOffsetY: CGFloat

    init(initialOffsetY: CGFloat) {
        effectiveOffsetY = initialOffsetY
        authoritativeOffsetY = initialOffsetY
    }

    mutating func updateAuthoritativeOffsetY(_ offsetY: CGFloat) {
        authoritativeOffsetY = offsetY
    }

    mutating func sample(
        rawOffsetY: CGFloat,
        maximumOffsetY: CGFloat,
        cellHeight: CGFloat
    ) -> Sample {
        let nextEffectiveOffsetY = min(max(rawOffsetY, 0), maximumOffsetY)
        effectiveOffsetY = nextEffectiveOffsetY
        let targetViewportRow = cellHeight > 0
            ? UInt64(max(0, floor(nextEffectiveOffsetY / cellHeight)))
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
