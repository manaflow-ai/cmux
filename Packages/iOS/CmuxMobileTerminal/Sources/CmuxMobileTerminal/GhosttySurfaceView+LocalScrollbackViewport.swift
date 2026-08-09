#if canImport(UIKit)
import GhosttyKit
import UIKit

extension GhosttySurfaceView {
    /// Moves the local Ghostty viewport to an absolute scrollback row.
    ///
    /// Requests are coalesced on the surface queue. Each request reads the
    /// current row-space revision before applying the target, so a replay or
    /// screen change cannot move a replacement buffer using stale geometry.
    ///
    /// - Parameter row: The zero-based row that should become the viewport top.
    public func applyLocalScrollbackViewport(row: UInt64) {
        pendingLocalViewportRow = row
        pumpLocalScrollbackViewport()
    }

    private func pumpLocalScrollbackViewport() {
        guard !localViewportApplyInFlight,
              let row = pendingLocalViewportRow,
              let surface else {
            return
        }
        pendingLocalViewportRow = nil
        localViewportApplyInFlight = true
        let operation = LocalScrollbackViewportOperation(
            surface: surface,
            generation: surfaceGeneration,
            row: row
        )
        outputQueue.async { [weak self] in
            var before = ghostty_surface_scrollbar_s()
            var after = ghostty_surface_scrollbar_s()
            let readBoundary = ghostty_surface_scrollbar(operation.surface, &before)
            let applied = readBoundary && ghostty_surface_scroll_to_row_if_revision(
                operation.surface,
                operation.row,
                before.row_space_revision,
                &after
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.localViewportApplyInFlight = false
                guard self.surface == operation.surface,
                      self.surfaceGeneration == operation.generation else {
                    return
                }
                if applied {
                    self.handleScrollBoundaryChange(
                        TerminalScrollBoundary(
                            totalRows: after.total,
                            viewportOffsetRows: after.offset,
                            visibleRows: after.len
                        )
                    )
                    self.drawForWakeup()
                    self.scheduleVisibleArtifactCountUpdate()
                }
                self.pumpLocalScrollbackViewport()
            }
        }
    }

    var pendingLocalViewportRow: UInt64? {
        get { localViewportState.pendingRow }
        set { localViewportState.pendingRow = newValue }
    }

    var localViewportApplyInFlight: Bool {
        get { localViewportState.applyInFlight }
        set { localViewportState.applyInFlight = newValue }
    }
}

private nonisolated struct LocalScrollbackViewportOperation: @unchecked Sendable {
    let surface: ghostty_surface_t
    let generation: UInt64
    let row: UInt64
}
#endif
