#if canImport(UIKit)
import GhosttyKit
import UIKit

extension GhosttySurfaceView {
    /// Apply the scroll to the phone's local Ghostty mirror immediately. On the
    /// primary screen this consumes the preloaded local scrollback window, so a
    /// drag/deceleration feels native while the Mac catches up. On alternate
    /// screens libghostty turns this into mouse-wheel bytes; the mirror is
    /// display-only and drops those bytes, so the authoritative Mac response
    /// remains the visible update for TUIs.
    func applyLocalScrollbackScroll(pixelDeltaY: Double, col: Int, row: Int) {
        guard pixelDeltaY != 0, let surface else { return }
        let displayScale = window?.windowScene?.screen.scale ?? traitCollection.displayScale
        let scale = max(Double(displayScale), 1)
        let size = ghostty_surface_size(surface)
        let cellWidthPt = max(Double(size.cell_width_px) / scale, 1)
        let cellHeightPt = max(Double(size.cell_height_px) / scale, 1)
        let posX = (Double(max(0, col)) + 0.5) * cellWidthPt
        let posY = (Double(max(0, row)) + 0.5) * cellHeightPt
        ghostty_surface_mouse_pos(surface, posX, posY, GHOSTTY_MODS_NONE)
        let precisionScrollMods: Int32 = 0b0000_0001
        ghostty_surface_mouse_scroll(surface, 0, pixelDeltaY, precisionScrollMods)
        drawForWakeup()
    }
}
#endif
