import AppKit

struct BrowserScreenshotTilePlacement: Equatable {
    let source: NSRect
    let destination: NSRect

    init?(
        tileSize: NSSize,
        origin: NSPoint,
        contentSize: NSSize,
        viewportSize: NSSize
    ) {
        let drawWidth = min(viewportSize.width, tileSize.width, max(0, contentSize.width - origin.x))
        let drawHeight = min(viewportSize.height, tileSize.height, max(0, contentSize.height - origin.y))
        guard drawWidth > 0, drawHeight > 0 else { return nil }

        source = NSRect(
            x: 0,
            y: max(0, tileSize.height - drawHeight),
            width: drawWidth,
            height: drawHeight
        )
        destination = NSRect(
            x: origin.x,
            y: contentSize.height - origin.y - drawHeight,
            width: drawWidth,
            height: drawHeight
        )
    }

    static func drawRects(
        tileSize: NSSize,
        origin: NSPoint,
        contentSize: NSSize,
        viewportSize: NSSize
    ) -> BrowserScreenshotTilePlacement? {
        BrowserScreenshotTilePlacement(
            tileSize: tileSize,
            origin: origin,
            contentSize: contentSize,
            viewportSize: viewportSize
        )
    }
}
