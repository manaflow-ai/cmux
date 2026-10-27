public import QuartzCore

/// Core Animation's side of the display-link seam: a `CADisplayLink` is a ``FrameLink``, and a
/// ``FrameRateRange`` reaches it (and a looping `CAAnimation`) as its `CAFrameRateRange`. The
/// schedulers name only ``FrameLink`` and ``FrameRateRange``.
extension CADisplayLink: FrameLink {
    @MainActor public func requestFrameRate(_ range: FrameRateRange) { preferredFrameRateRange = CAFrameRateRange(range) }
}

extension CAFrameRateRange {
    /// `range` as Core Animation takes it.
    public init(_ range: FrameRateRange) {
        self.init(minimum: range.minimum, maximum: range.maximum, preferred: range.preferred)
    }
}

extension FrameRate {
    /// ``preferredRange`` as a display link or a `CAAnimation` takes it.
    public var range: CAFrameRateRange { CAFrameRateRange(preferredRange) }
}
