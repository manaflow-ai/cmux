import AppKit
import CmuxTerminal

extension GhosttyNSView {
    /// Invalidates a queued metric snapshot by reading the current runtime.
    /// Ghostty reports backing pixels; AppKit scrolling and hit testing use points.
    @discardableResult
    func synchronizeCellMetrics() -> Bool {
        guard let size = terminalSurface?.cellSizePoints(),
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              cellSize != size else { return false }
        cellSize = size
        NotificationCenter.default.post(
            name: .ghosttyDidUpdateCellSize,
            object: self,
            userInfo: [GhosttyNotificationKey.cellSize: size]
        )
        return true
    }
}
