public import CoreGraphics

/// The size a small page surface reports to its native host (the sidebar's update surfaces), in
/// points: its content height, its own width (0: it fills the host) and the room its open overlay
/// needs above it (0: none). The page reports CSS px; the page is zoomed (the interface scale), so
/// one CSS px is `zoom` points.
public nonisolated struct PageSurfaceSize: Equatable, Sendable {
    public private(set) var height: CGFloat = 0
    public private(set) var width: CGFloat = 0
    public private(set) var overlay: CGFloat = 0
    /// A report has arrived: the first one counts as a change even when it is all 0 (a page with
    /// nothing to show).
    public private(set) var reported = false
    /// The last report as the page sent it, CSS px, so a new zoom can take it again.
    private var cssHeight: CGFloat = 0, cssWidth: CGFloat = 0, cssOverlay: CGFloat = 0

    public init() {}

    /// Takes one report; true when the host must lay the surface out again.
    public mutating func take(height: CGFloat, width: CGFloat, overlay: CGFloat, zoom: CGFloat) -> Bool {
        (cssHeight, cssWidth, cssOverlay) = (height, width, overlay)
        let next = (max(0, (height * zoom).rounded(.up)), max(0, (width * zoom).rounded(.up)), max(0, (overlay * zoom).rounded(.up)))
        guard next != (self.height, self.width, self.overlay) || !reported else { return false }
        (self.height, self.width, self.overlay, reported) = (next.0, next.1, next.2, true)
        return true
    }

    /// Takes the last report again at a new zoom (a live interface scale change: the page's CSS size
    /// stays, so it sends no new report); true when the host must lay the surface out again.
    public mutating func rezoom(_ zoom: CGFloat) -> Bool {
        guard reported else { return false }
        return take(height: cssHeight, width: cssWidth, overlay: cssOverlay, zoom: zoom)
    }
}
