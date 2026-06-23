public import AppKit
import Foundation

extension NSEvent {
    /// The multiplicative step applied to a preview's scale for a single
    /// keyboard/button zoom-in or zoom-out (1.25 = a 25% change per step).
    ///
    /// Lives on `NSEvent` so the file-preview zoom math (scroll factor,
    /// modifier detection, discrete step) is reachable from one receiver the
    /// preview surfaces already hold.
    public static let filePreviewZoomStep: CGFloat = 1.25

    /// Whether this event carries a zoom modifier (Option or Command) for
    /// scroll-to-zoom in the file preview.
    public var filePreviewHasZoomModifier: Bool {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags.contains(.option) || flags.contains(.command)
    }

    /// The continuous zoom factor for a scroll event in the file preview,
    /// derived from this event's scrolling delta and clamped to `[0.2, 5.0]`.
    public var filePreviewScrollZoomFactor: CGFloat {
        let rawDelta = scrollingDeltaY != 0 ? scrollingDeltaY : deltaY
        let normalizedDelta = hasPreciseScrollingDeltas ? rawDelta : rawDelta * 8
        let factor = pow(1.0025, normalizedDelta)
        guard factor.isFinite else { return 1 }
        return min(max(factor, 0.2), 5.0)
    }
}
