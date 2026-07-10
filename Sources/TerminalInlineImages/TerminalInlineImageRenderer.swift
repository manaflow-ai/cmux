import AppKit
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
        let size = ghostty_surface_size(surface)
        let scale = max(
            surfaceView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1,
            1
        )
        let cellWidth = CGFloat(size.cell_width_px) / scale
        let cellHeight = CGFloat(size.cell_height_px) / scale
        guard cellWidth > 0, cellHeight > 0 else {
            overlayView.clear()
            return
        }
        let xInset = max(0, (surfaceView.bounds.width - CGFloat(size.columns) * cellWidth) / 2)
        let yInset = max(0, (surfaceView.bounds.height - CGFloat(size.rows) * cellHeight) / 2)
        let items = annotations.compactMap { annotation -> TerminalInlineImageOverlayItem? in
            guard let thumbnail = thumbnailsByID[annotation.id] else { return nil }
            let rowTopFromTop = yInset + CGFloat(annotation.rowIndex) * cellHeight
            let cellRect = CGRect(
                x: xInset,
                y: surfaceView.bounds.height - rowTopFromTop - cellHeight,
                width: cellWidth,
                height: cellHeight
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
