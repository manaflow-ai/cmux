import AppKit
import CmuxTerminalCore
import GhosttyKit

/// Projects reconciled annotations and thumbnails into the AppKit overlay.
@MainActor
struct TerminalInlineImageRenderer {
    func render(
        hostedView: GhosttySurfaceScrollView,
        overlayView: TerminalInlineImageOverlayView,
        annotations: [TerminalInlineImageAnnotation],
        thumbnailsByID: [UUID: TerminalInlineImageThumbnail]
    ) {
        guard let surface = hostedView.surfaceView.terminalSurface?.surface else {
            overlayView.clear()
            return
        }
        let surfaceView = hostedView.surfaceView
        guard let metrics = surfaceView.keyboardCopyModeGridMetrics(surface: surface) else {
            overlayView.clear()
            return
        }
        let items = annotations.compactMap { annotation -> TerminalInlineImageOverlayItem? in
            guard annotation.rowIndex >= 0,
                  annotation.rowIndex < metrics.rows,
                  let thumbnail = thumbnailsByID[annotation.id] else {
                return nil
            }
            let cellRect = metrics.appKitRect(
                for: TerminalKeyboardCopyModeCursor(row: annotation.rowIndex, column: 0)
            )
            return TerminalInlineImageOverlayItem(
                annotation: annotation,
                thumbnail: thumbnail,
                anchorRect: overlayView.convert(cellRect, from: surfaceView)
            )
        }
        overlayView.update(items: items)
    }
}
