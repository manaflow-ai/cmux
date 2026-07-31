#if canImport(UIKit)
extension GhosttySurfaceView {
    /// Applies Ghostty's authoritative viewport position to UIKit overlays.
    func handleScrollbarUpdate(total: UInt64, offset: UInt64, length: UInt64) {
        #if DEBUG
        debugLastScrollbar = (
            total: Int(clamping: total),
            offset: Int(clamping: offset),
            len: Int(clamping: length)
        )
        #endif

        let visibleLength = min(total, length)
        let isAtBottom = offset >= total - visibleLength
        guard viewportIsAtScrollbackBottom != isAtBottom else { return }

        viewportIsAtScrollbackBottom = isAtBottom
        updateCursorOverlay()
    }
}
#endif
