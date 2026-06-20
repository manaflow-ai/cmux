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
            + "replayRows=\(localScrollbackModel.replayScrollbackRows)"
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
        guard pixelDeltaY != 0, let surface else { return }
        let size = ghostty_surface_size(surface)
        let cellHeightPx = max(Double(size.cell_height_px), 1)
        let rowDelta = pixelDeltaY / cellHeightPx
        let result = localScrollbackModel.applyGesture(rowDelta: rowDelta)
        MobileDebugLog.anchormux(
            "local.scroll.apply px=\(String(format: "%.1f", pixelDeltaY)) "
            + "rowDelta=\(String(format: "%.2f", rowDelta)) "
            + "offset=\(String(format: "%.2f", result.previousOffset))->\(String(format: "%.2f", result.rowOffset)) "
            + "max=\(String(format: "%.2f", result.maxRowOffset)) "
            + "cellPx=\(String(format: "%.1f", cellHeightPx))"
        )
        ghostty_surface_scroll_to_offset(surface, result.rowOffset)
        updateCursorOverlay()
        debugLogLocalScrollViewport(surface: surface, requestedOffset: result.rowOffset)
        drawForWakeup()
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
