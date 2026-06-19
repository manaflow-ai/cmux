#if canImport(UIKit)
import GhosttyKit
import UIKit

extension GhosttySurfaceView {
    /// Apply a primary-screen scrollback gesture to the phone's local Ghostty
    /// mirror immediately. This consumes the preloaded local scrollback window,
    /// so a drag/deceleration feels native without waiting for the Mac.
    func applyLocalScrollbackScroll(pixelDeltaY: Double, col: Int, row: Int) {
        guard pixelDeltaY != 0, let surface else { return }
        let size = ghostty_surface_size(surface)
        let cellHeightPx = max(Double(size.cell_height_px), 1)
        let rowDelta = pixelDeltaY / cellHeightPx
        localScrollRowOffset = min(
            max(localScrollRowOffset - rowDelta, 0),
            localScrollbackMaxRowOffset
        )
        ghostty_surface_scroll_to_offset(surface, localScrollRowOffset)
        drawForWakeup()
    }
}
#endif
