#if canImport(UIKit)
public import CMUXMobileCore
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
        guard let surface, !isDismantled, !renderPipelineRecoveryPaused else { return nil }
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

    /// Applies one session-owned optimistic scroll operation on the same FIFO
    /// queue as terminal output and surface disposal. The mounted terminal
    /// scroll session bounds/coalesces requests before they reach this method,
    /// so this view never owns a second pending-scroll scheduler.
    @discardableResult
    public func applyLocalScrollbackScrollAndWait(lines: Double, col: Int, row: Int) async -> Bool {
        await applyLocalScrollbackScrollAndWait([
            MobileTerminalScrollRun(lines: lines, col: col, row: row),
        ])
    }

    /// Applies a bounded direction-preserving batch as one surface FIFO item.
    /// Opposite runs must remain separate because a clamp at either boundary
    /// makes `+n` followed by `-n` differ from a net zero delta.
    @discardableResult
    public func applyLocalScrollbackScrollAndWait(_ runs: [MobileTerminalScrollRun]) async -> Bool {
        let hasNonzeroRun = runs.contains { $0.hasEffect }
        guard hasNonzeroRun, let state = localScrollbackScrollState() else {
            return !hasNonzeroRun
        }
        return await performLocalScrollbackOperation(state: state) {
            Self.applyLocalScrollbackRuns(runs, to: state.surface, scale: state.scale)
            return true
        }
    }

    nonisolated static func applyLocalScrollbackRuns(
        _ runs: [MobileTerminalScrollRun],
        to surface: ghostty_surface_t,
        scale: Double
    ) {
        let size = ghostty_surface_size(surface)
        let cellWidthPt = max(Double(size.cell_width_px) / scale, 1)
        let cellHeightPt = max(Double(size.cell_height_px) / scale, 1)
        for run in runs where run.hasEffect {
            let posX = (Double(run.col) + 0.5) * cellWidthPt
            let posY = (Double(run.row) + 0.5) * cellHeightPt
            ghostty_surface_mouse_pos(surface, posX, posY, GHOSTTY_MODS_NONE)
            if let primaryRows = run.primaryRows {
                ghostty_surface_mouse_scroll_with_viewport_rows(
                    surface,
                    0,
                    run.lines,
                    Int32(clamping: primaryRows),
                    0
                )
            } else {
                ghostty_surface_mouse_scroll(surface, 0, run.lines, 0)
            }
        }
    }

    /// Positions a bidirectional authoritative snapshot at its captured
    /// viewport after replay. `scroll_page_lines` is exact and bypasses the
    /// user's mouse-scroll multiplier, unlike synthesizing a wheel gesture.
    @discardableResult
    public func positionAuthoritativeScrollbackViewportAndWait(rowsFromBottom: Int) async -> Bool {
        let rows = max(0, rowsFromBottom)
        guard let state = localScrollbackScrollState() else { return false }
        return await performLocalScrollbackOperation(state: state) {
            Self.positionAuthoritativeScrollbackViewport(
                state.surface,
                rowsFromBottom: rows
            )
        }
    }

    @discardableResult
    public func scrollToBottomAndWait() async -> Bool {
        guard let state = localScrollbackScrollState() else { return false }
        return await performLocalScrollbackOperation(state: state) {
            Self.positionAuthoritativeScrollbackViewport(state.surface, rowsFromBottom: 0)
        }
    }

    /// Establishes an absolute local scrollback position after a full replay.
    /// The row-space revision makes the read and update a compare-and-swap, so
    /// concurrent destructive output cannot move this operation onto a newer
    /// history incarnation.
    nonisolated static func positionAuthoritativeScrollbackViewport(
        _ surface: ghostty_surface_t,
        rowsFromBottom: Int,
        expectedReconstructedRowCount: Int? = nil
    ) -> Bool {
        var current = ghostty_surface_scrollbar_s()
        guard ghostty_surface_scrollbar(surface, &current) else { return false }

        if let expectedReconstructedRowCount {
            let expectedTotal = max(
                UInt64(clamping: expectedReconstructedRowCount),
                current.len
            )
            guard current.total == expectedTotal else { return false }
        }

        let maximumOffset = current.total > current.len
            ? current.total - current.len
            : 0
        let distance = min(UInt64(clamping: max(0, rowsFromBottom)), maximumOffset)
        let target = maximumOffset - distance
        var positioned = ghostty_surface_scrollbar_s()
        return ghostty_surface_scroll_to_row_if_revision(
            surface,
            target,
            current.row_space_revision,
            &positioned
        ) && positioned.offset == target
    }

    /// Stops UIKit drag/deceleration without mutating Ghostty. The shell then
    /// inserts the bottom snap into its causal surface mutation stream.
    public func cancelScrollMomentum() {
        resetPendingScrollInput()
        scrollMechanicsView.setContentOffset(scrollMechanicsView.contentOffset, animated: false)
    }

    private func performLocalScrollbackOperation(
        state: GhosttySurfaceWorkSnapshot,
        operation: @escaping @Sendable () -> Bool
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let operationID = registerPendingLocalScrollApply(continuation: continuation)
            state.queue.async { [weak self] in
                let operationApplied = operation()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let isCurrent = self.surface == state.surface
                        && self.surfaceGeneration == state.generation
                        && !self.isDismantled
                    if isCurrent {
                        self.requestDrawAfterLocalScrollbackScroll(generation: state.generation)
                        self.scheduleVisibleArtifactCountUpdate()
                    }
                    self.completePendingLocalScrollApply(
                        id: operationID,
                        returning: operationApplied && isCurrent
                    )
                }
            }
        }
    }

    private func registerPendingLocalScrollApply(
        continuation: CheckedContinuation<Bool, Never>
    ) -> UInt64 {
        let operationID = makeSurfaceOperationID()
        if let existing = pendingLocalScrollApply {
            pendingLocalScrollApply = nil
            existing.continuation.resume(returning: false)
        }
        pendingLocalScrollApply = PendingSurfaceOperation(
            id: operationID,
            startedAt: CACurrentMediaTime(),
            byteCount: nil,
            continuation: continuation
        )
        ensureSurfaceOperationDeadlinePump()
        return operationID
    }

    @discardableResult
    func completePendingLocalScrollApply(id: UInt64, returning result: Bool) -> Bool {
        guard let pending = pendingLocalScrollApply, pending.id == id else { return false }
        pendingLocalScrollApply = nil
        pending.continuation.resume(returning: result)
        return true
    }
}
#endif
