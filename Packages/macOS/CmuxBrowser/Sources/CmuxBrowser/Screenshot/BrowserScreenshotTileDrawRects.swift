public import AppKit

/// The source and destination rectangles for compositing one screenshot tile
/// into a full-page bitmap.
///
/// ``source`` is the region of the captured tile image to read; ``destination``
/// is where that region lands in the stitched output, expressed in the output
/// bitmap's bottom-left-origin coordinate space.
public struct BrowserScreenshotTileDrawRects: Equatable {
    /// The region of the captured tile image to copy from.
    public let source: NSRect

    /// The region of the stitched output bitmap to draw into.
    public let destination: NSRect

    /// Creates a tile draw-rect pair.
    /// - Parameters:
    ///   - source: the region of the captured tile image to copy from.
    ///   - destination: the region of the stitched output bitmap to draw into.
    public init(source: NSRect, destination: NSRect) {
        self.source = source
        self.destination = destination
    }
}
