public import AppKit

/// Zoom-interaction policy for the file-preview surfaces (PDF, image, and text editor).
///
/// Translates raw `NSEvent`s into the magnification factors the preview views apply: a
/// discrete multiplicative `step` for keyboard/button zoom, a modifier test that arms
/// scroll-to-zoom, and a continuous per-scroll factor. The computations are pure and
/// byte-faithful to the legacy helpers; `step` is the only configurable state.
public struct FilePreviewZoomInteraction: Sendable {
    /// Discrete multiplicative zoom step applied on each keyboard or button zoom (1.25×).
    public let step: CGFloat

    /// Creates a zoom-interaction policy.
    /// - Parameter step: Discrete multiplicative step for keyboard/button zoom. Defaults to 1.25.
    public init(step: CGFloat = 1.25) {
        self.step = step
    }

    /// The shared file-preview zoom policy (1.25× discrete step).
    public static let standard = FilePreviewZoomInteraction()

    /// Whether `event` carries the Option or Command modifier that arms scroll-to-zoom.
    public func hasZoomModifier(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags.contains(.option) || flags.contains(.command)
    }

    /// The continuous magnification factor for a scroll `event`, clamped to `[0.2, 5.0]`.
    ///
    /// Uses precise scrolling deltas when available and scales coarse line deltas by 8 so
    /// trackpad and mouse-wheel zoom feel consistent. Returns 1 for non-finite input.
    public func zoomFactor(forScroll event: NSEvent) -> CGFloat {
        let rawDelta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
        let normalizedDelta = event.hasPreciseScrollingDeltas ? rawDelta : rawDelta * 8
        let factor = pow(1.0025, normalizedDelta)
        guard factor.isFinite else { return 1 }
        return min(max(factor, 0.2), 5.0)
    }
}
