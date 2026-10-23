#if DEBUG
import AppKit

extension PaletteController {
    /// Flings the open palette's list under a resting pointer for `frames` display refreshes and
    /// returns what it cost (the `debug.palette.fling` socket verb). DEBUG builds only.
    ///
    /// - Parameters:
    ///   - frames: Display refreshes to scroll, 1 to 180 (1.5 s at 120 Hz, inside the control
    ///     router's 2 s deadline; a bench calls again for a longer fling).
    ///   - pointsPerFrame: Points the list moves each refresh (a fast fling moves a row or more).
    ///   - pointerFraction: Where the pointer rests over the list, as a fraction of its height.
    /// - Returns: The fling's report, or nil when the palette is not open or not in a window.
    public func debugFling(frames: Int, pointsPerFrame: Double, pointerFraction: Double) async -> PaletteFlingReport? {
        guard isVisible, let content = contentView, content.window != nil else { return nil }
        let probe = PaletteFlingProbe(content: content, frames: min(max(frames, 1), 180),
                                      pointsPerFrame: CGFloat(pointsPerFrame), pointerFraction: CGFloat(pointerFraction))
        return await probe.run()
    }
}
#endif
