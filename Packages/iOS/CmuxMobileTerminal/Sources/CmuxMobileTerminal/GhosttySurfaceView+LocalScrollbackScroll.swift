#if canImport(UIKit)
import GhosttyKit
import UIKit

extension GhosttySurfaceView {
    private var localScrollbackScreenScale: CGFloat {
        if let screen = window?.windowScene?.screen {
            return screen.scale
        }
        let traitScale = traitCollection.displayScale
        return traitScale > 0 ? traitScale : 2
    }

    func localScrollbackScrollState() -> GhosttySurfaceWorkSnapshot? {
        guard let surface, !isDismantled else { return nil }
        return GhosttySurfaceWorkSnapshot(
            surface: surface,
            generation: surfaceGeneration,
            scale: Double(max(localScrollbackScreenScale, 1)),
            queue: outputQueue
        )
    }

    func requestDrawAfterLocalScrollbackScroll(generation: UInt64) {
        guard surface != nil,
              surfaceGeneration == generation else {
            return
        }
        drawForWakeup()
    }

    /// Apply the scroll to the phone's local Ghostty mirror immediately. On the
    /// primary screen this consumes the preloaded local scrollback window, so a
    /// drag/deceleration feels native while the Mac catches up. On alternate
    /// screens libghostty turns this into mouse-wheel bytes; the mirror is
    /// display-only and drops those bytes, so the authoritative Mac response
    /// remains the visible update for TUIs.
    func applyLocalScrollbackScroll(lines: Double, col: Int, row: Int) {
        guard lines != 0,
              let state = localScrollbackScrollState() else {
            return
        }
        let generation = state.generation
        let scale = state.scale
        let clampedCol = max(0, col)
        let clampedRow = max(0, row)
        state.queue.async { [weak self] in
            let size = ghostty_surface_size(state.surface)
            let cellWidthPt = max(Double(size.cell_width_px) / scale, 1)
            let cellHeightPt = max(Double(size.cell_height_px) / scale, 1)
            let posX = (Double(clampedCol) + 0.5) * cellWidthPt
            let posY = (Double(clampedRow) + 0.5) * cellHeightPt
            ghostty_surface_mouse_pos(state.surface, posX, posY, GHOSTTY_MODS_NONE)
            ghostty_surface_mouse_scroll(state.surface, 0, lines, 0)
            Task { @MainActor in
                self?.requestDrawAfterLocalScrollbackScroll(generation: generation)
            }
        }
    }
}
#endif
