/// A constant-size representation of ordered, clamped font-size adjustments.
///
/// Repeatedly applying the integral point deltas used by font-size shortcuts
/// produces another clamped translation. `offset` preserves that translation
/// while the two endpoint results preserve ordering at Ghostty's bounds.
public struct TerminalFontSizeDeltaTransform: Equatable, Sendable {
    private var offset: Float32
    private var minimumResult: Float32
    private var maximumResult: Float32

    /// The identity transform.
    public init() {
        offset = 0
        minimumResult = TerminalFontSizePolicy.minimumRuntimePoints
        maximumResult = TerminalFontSizePolicy.maximumRuntimePoints
    }

    /// Builds a transform for an ordered sequence of point deltas.
    public init(orderedRuntimePointDeltas: [Float32]) {
        self.init()
        for delta in orderedRuntimePointDeltas {
            append(delta)
        }
    }

    /// Whether applying this transform leaves every supported point size intact.
    public var isIdentity: Bool {
        offset == 0
            && minimumResult == TerminalFontSizePolicy.minimumRuntimePoints
            && maximumResult == TerminalFontSizePolicy.maximumRuntimePoints
    }

    /// Appends one finite, non-zero point delta.
    public mutating func append(_ deltaRuntimePoints: Float32) {
        guard deltaRuntimePoints.isFinite, deltaRuntimePoints != 0 else { return }

        offset = terminalFontSizeSaturatedSum(
            offset,
            deltaRuntimePoints
        )

        let policy = TerminalFontSizePolicy()
        minimumResult = policy.clampedRuntimePoints(
            minimumResult + deltaRuntimePoints
        )
        maximumResult = policy.clampedRuntimePoints(
            maximumResult + deltaRuntimePoints
        )
    }

    /// Appends another already-coalesced transform.
    public mutating func append(
        contentsOf transform: TerminalFontSizeDeltaTransform
    ) {
        offset = terminalFontSizeSaturatedSum(
            offset,
            transform.offset
        )
        minimumResult = transform.applying(to: minimumResult)
        maximumResult = transform.applying(to: maximumResult)
    }

    /// Applies all represented deltas to one runtime point size.
    public func applying(to runtimePoints: Float32) -> Float32 {
        let policy = TerminalFontSizePolicy()
        let translated = policy.clampedRuntimePoints(
            policy.clampedRuntimePoints(runtimePoints) + offset
        )
        return min(maximumResult, max(minimumResult, translated))
    }

}

private func terminalFontSizeSaturatedSum(
    _ lhs: Float32,
    _ rhs: Float32
) -> Float32 {
    let sum = lhs + rhs
    guard !sum.isFinite else { return sum }
    return rhs > 0
        ? Float32.greatestFiniteMagnitude
        : -Float32.greatestFiniteMagnitude
}
