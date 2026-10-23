#if DEBUG
import AppKit

extension PaletteController {
    /// The longest fling one call runs, in seconds: the control router's 2 s deadline less room
    /// for the reply and one long last frame.
    public static let maximumFlingSeconds = 1.5

    /// Flings the open palette's list under a resting pointer for `seconds` and returns what it
    /// cost (the `debug.palette.fling` socket verb). DEBUG builds only.
    ///
    /// - Parameters:
    ///   - seconds: How long to scroll, from the first display refresh, 0 to
    ///     ``maximumFlingSeconds``. It is a time, not a frame count, so the fling ends inside the
    ///     control router's 2 s deadline at any refresh rate and however many frames run long (a
    ///     slow build is the case the bench exists to catch); a bench calls again for a longer
    ///     fling. The report counts the frames that really ran.
    ///   - pointsPerFrame: Points the list moves each refresh (a fast fling moves a row or more).
    ///   - pointerFraction: Where the pointer rests over the list, as a fraction of its height.
    /// - Returns: The fling's report, or nil when the palette is not open or not in a window.
    public func debugFling(seconds: Double, pointsPerFrame: Double, pointerFraction: Double) async -> PaletteFlingReport? {
        guard isVisible, let content = contentView, content.window != nil else { return nil }
        let probe = PaletteFlingProbe(content: content, duration: min(max(seconds, 0), Self.maximumFlingSeconds),
                                      pointsPerFrame: CGFloat(pointsPerFrame), pointerFraction: CGFloat(pointerFraction))
        return await probe.run()
    }
}
#endif
