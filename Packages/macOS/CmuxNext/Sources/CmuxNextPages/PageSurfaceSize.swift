public import CoreGraphics

/// The size a small page surface reports to its native host (the sidebar's update surfaces), in
/// points: its content height, its own width (0: it fills the host) and the room its open overlay
/// needs above it (0: none), and the height its open overlay has once open (0: closed or closing).
/// The page reports CSS px; the page is zoomed (the interface scale), so
/// one CSS px is `zoom` points.
public nonisolated struct PageSurfaceSize: Equatable, Sendable {
    public private(set) var height: CGFloat = 0
    public private(set) var width: CGFloat = 0
    public private(set) var overlay: CGFloat = 0
    public private(set) var preview: CGFloat = 0
    /// A report has arrived: the first one counts as a change even when it is all 0 (a page with
    /// nothing to show).
    public private(set) var reported = false
    /// The last report as the page sent it, CSS px, so a new zoom can take it again.
    private var cssHeight: CGFloat = 0, cssWidth: CGFloat = 0, cssOverlay: CGFloat = 0, cssPreview: CGFloat = 0

    public init() {}

    /// Takes one report; true when the host must lay the surface out again.
    public mutating func take(height: CGFloat, width: CGFloat, overlay: CGFloat, preview: CGFloat = 0, zoom: CGFloat) -> Bool {
        (cssHeight, cssWidth, cssOverlay, cssPreview) = (height, width, overlay, preview)
        let points = { (value: CGFloat) in max(0, (value * zoom).rounded(.up)) }
        let next = (points(height), points(width), points(overlay), points(preview))
        guard next != (self.height, self.width, self.overlay, self.preview) || !reported else { return false }
        (self.height, self.width, self.overlay, self.preview, reported) = (next.0, next.1, next.2, next.3, true)
        return true
    }

    /// Takes the last report again at a new zoom (a live interface scale change: the page's CSS size
    /// stays, so it sends no new report); true when the host must lay the surface out again.
    public mutating func rezoom(_ zoom: CGFloat) -> Bool {
        guard reported else { return false }
        return take(height: cssHeight, width: cssWidth, overlay: cssOverlay, preview: cssPreview, zoom: zoom)
    }
}
