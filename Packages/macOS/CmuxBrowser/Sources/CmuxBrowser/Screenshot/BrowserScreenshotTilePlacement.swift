public import AppKit

/// Pure geometry for tiling a web page into viewport-sized screenshot tiles and
/// compositing each captured tile back into a full-page bitmap.
///
/// A placement is fixed by the page's full scrollable ``contentSize`` and the
/// capture ``viewportSize``. ``horizontalTileOrigins`` and ``verticalTileOrigins``
/// give the scroll origins to capture along each axis, and
/// ``drawRects(tileSize:origin:)`` maps a captured tile into the stitched output.
public struct BrowserScreenshotTilePlacement: Equatable {
    /// The full scrollable content size of the page being captured.
    public let contentSize: NSSize

    /// The visible viewport size used for each tile capture.
    public let viewportSize: NSSize

    /// Creates a tile placement for a page capture.
    /// - Parameters:
    ///   - contentSize: the full scrollable content size of the page.
    ///   - viewportSize: the visible viewport size used per tile capture.
    public init(contentSize: NSSize, viewportSize: NSSize) {
        self.contentSize = contentSize
        self.viewportSize = viewportSize
    }

    /// The horizontal scroll origins at which to capture tiles across the page.
    public var horizontalTileOrigins: [CGFloat] {
        Self.tileOrigins(contentLength: contentSize.width, viewportLength: viewportSize.width)
    }

    /// The vertical scroll origins at which to capture tiles down the page.
    public var verticalTileOrigins: [CGFloat] {
        Self.tileOrigins(contentLength: contentSize.height, viewportLength: viewportSize.height)
    }

    /// Computes the source and destination rectangles for compositing one
    /// captured tile into the full-page bitmap.
    ///
    /// - Parameters:
    ///   - tileSize: the pixel size of the captured tile image.
    ///   - origin: the scroll origin at which the tile was captured.
    /// - Returns: the draw rectangles, or `nil` when the tile contributes no
    ///   visible pixels at this origin.
    public func drawRects(tileSize: NSSize, origin: NSPoint) -> BrowserScreenshotTileDrawRects? {
        let drawWidth = min(viewportSize.width, tileSize.width, max(0, contentSize.width - origin.x))
        let drawHeight = min(viewportSize.height, tileSize.height, max(0, contentSize.height - origin.y))
        guard drawWidth > 0, drawHeight > 0 else { return nil }

        return BrowserScreenshotTileDrawRects(
            source: NSRect(
                x: 0,
                y: max(0, tileSize.height - drawHeight),
                width: drawWidth,
                height: drawHeight
            ),
            destination: NSRect(
                x: origin.x,
                y: contentSize.height - origin.y - drawHeight,
                width: drawWidth,
                height: drawHeight
            )
        )
    }

    private static func tileOrigins(contentLength: CGFloat, viewportLength: CGFloat) -> [CGFloat] {
        guard contentLength > 0, viewportLength > 0 else { return [0] }
        guard contentLength > viewportLength else { return [0] }

        var origins: [CGFloat] = []
        var next: CGFloat = 0
        let last = max(0, contentLength - viewportLength)
        while next < last {
            origins.append(next)
            next += viewportLength
        }
        if origins.last.map({ abs($0 - last) > 0.5 }) ?? true {
            origins.append(last)
        }
        return origins
    }
}
