#if canImport(UIKit)
import CmuxMobileDiagnostics
import GhosttyKit
import UIKit

extension GhosttySurfaceView {
    var isViewingLiveBottom: Bool {
        localScrollbackModel.isViewingLiveBottom
    }

    func updateLocalScrollbackBounds(total: UInt64, offset: UInt64, len: UInt64) {
        let result = localScrollbackModel.updateBounds(total: total, offset: offset, len: len)
        updateCursorOverlay()

        #if DEBUG
        MobileDebugLog.anchormux(
            "local.scroll.bounds total=\(total) offset=\(offset) len=\(len) "
            + "max=\(String(format: "%.2f", result.maxRowOffset)) "
            + "rowOffset=\(String(format: "%.2f", result.rowOffset)) "
            + "wasAtBottom=\(result.wasAtBottom) "
            + "replayRows=\(localScrollbackModel.replayScrollbackRows) "
            + "expectedTotal=\(result.expectedTotalRows) "
            + "retainedTotal=\(result.observation.totalRows) "
            + "retention=\(result.mirrorRetention)"
            + " hydration=\(localScrollbackModel.mirrorHydration)"
        )
        if result.mirrorTruncated {
            MobileDebugLog.anchormux(
                "local.scroll.truncated expectedTotal=\(result.expectedTotalRows) actualTotal=\(total) "
                + "missing=\(result.mirrorRetention.missingRows) len=\(len)"
            )
        }
        #endif
    }

    /// Apply a primary-screen scrollback gesture to the phone's local Ghostty
    /// mirror immediately. This consumes the preloaded local scrollback window,
    /// so a drag/deceleration feels native without waiting for the Mac.
    func applyLocalScrollbackScroll(pixelDeltaY: Double, col: Int, row: Int) {
        guard pixelDeltaY != 0 else { return }
        let cellHeightPx: Double
        if cellPixelSize.height > 0 {
            cellHeightPx = max(Double(cellPixelSize.height), 1)
        } else if let surface {
            let size = ghostty_surface_size(surface)
            cellHeightPx = max(Double(size.cell_height_px), 1)
        } else {
            cellHeightPx = 1
        }
        let rowDelta = pixelDeltaY / cellHeightPx
        let result = localScrollbackModel.applyGesture(rowDelta: rowDelta)
        MobileDebugLog.anchormux(
            "local.scroll.apply px=\(String(format: "%.1f", pixelDeltaY)) "
            + "rowDelta=\(String(format: "%.2f", rowDelta)) "
            + "offset=\(String(format: "%.2f", result.previousOffset))->\(String(format: "%.2f", result.rowOffset)) "
            + "max=\(String(format: "%.2f", result.maxRowOffset)) "
            + "cellPx=\(String(format: "%.1f", cellHeightPx))"
        )
        if let surface {
            Self.outputQueue.async { [weak self] in
                ghostty_surface_scroll_to_offset(surface, result.rowOffset)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.updateCursorOverlay()
                    self.drawForWakeup()
                }
            }
            debugLogLocalScrollViewport(surface: surface, requestedOffset: result.rowOffset)
        } else if renderGridSnapshot != nil {
            renderSemanticRenderGridSnapshot()
            debugLogLocalScrollViewport(requestedOffset: result.rowOffset)
        } else {
            MobileDebugLog.anchormux(
                "local.scroll.viewport_unavailable requested=\(String(format: "%.2f", result.rowOffset))"
            )
        }
    }

    private func debugLogLocalScrollViewport(requestedOffset: Double) {
        #if DEBUG
        let now = CACurrentMediaTime()
        guard now - lastLocalScrollViewportLogTime > 0.5 else { return }
        lastLocalScrollViewportLogTime = now
        let surfaceID = hostSurfaceID ?? "nil"
        let activeScreen = activeScreen.rawValue
        let maxOffset = localScrollbackModel.maxRowOffset
        let replayRows = localScrollbackModel.replayScrollbackRows
        let mirrorTruncated = localScrollbackModel.mirrorTruncated
        let viewport = visibleSnapshotTextForTesting()
        let lines = viewport
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let first = Self.debugLineSummary(nonEmpty.first)
        let last = Self.debugLineSummary(nonEmpty.last)
        MobileDebugLog.anchormux(
            "local.scroll.viewport surface=\(surfaceID) screen=\(activeScreen) "
            + "requested=\(String(format: "%.2f", requestedOffset)) "
            + "max=\(String(format: "%.2f", maxOffset)) replayRows=\(replayRows) "
            + "truncated=\(mirrorTruncated) "
            + "lineCount=\(lines.count) first=\(first) last=\(last)"
        )
        #endif
    }

    private func debugLogLocalScrollViewport(surface: ghostty_surface_t, requestedOffset: Double) {
        #if DEBUG
        let now = CACurrentMediaTime()
        guard now - lastLocalScrollViewportLogTime > 0.5 else { return }
        lastLocalScrollViewportLogTime = now
        let surfaceID = hostSurfaceID ?? "nil"
        let activeScreen = activeScreen.rawValue
        let maxOffset = localScrollbackModel.maxRowOffset
        let replayRows = localScrollbackModel.replayScrollbackRows
        let mirrorTruncated = localScrollbackModel.mirrorTruncated
        Self.outputQueue.async {
            let viewport = Self.surfaceText(surface, pointTag: GHOSTTY_POINT_VIEWPORT) ?? ""
            let lines = viewport
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let first = Self.debugLineSummary(nonEmpty.first)
            let last = Self.debugLineSummary(nonEmpty.last)
            MobileDebugLog.anchormux(
                "local.scroll.viewport surface=\(surfaceID) screen=\(activeScreen) "
                + "requested=\(String(format: "%.2f", requestedOffset)) "
                + "max=\(String(format: "%.2f", maxOffset)) replayRows=\(replayRows) "
                + "truncated=\(mirrorTruncated) "
                + "lineCount=\(lines.count) first=\(first) last=\(last)"
            )
        }
        #endif
    }

    nonisolated private static func debugLineSummary(_ line: String?) -> String {
        guard let line else { return "nil" }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let range = trimmed.range(of: #"Live tail line \d+"#, options: .regularExpression) {
            return String(trimmed[range])
        }
        if trimmed.count > 48 {
            return String(trimmed.prefix(48))
        }
        return trimmed.isEmpty ? "empty" : trimmed
    }
}
#endif
