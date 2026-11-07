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

    public init() {}

    /// Takes one report; true when the host must lay the surface out again.
    public mutating func take(height: CGFloat, width: CGFloat, overlay: CGFloat, zoom: CGFloat) -> Bool {
        let next = (max(0, (height * zoom).rounded(.up)), max(0, (width * zoom).rounded(.up)), max(0, (overlay * zoom).rounded(.up)))
        guard next != (self.height, self.width, self.overlay) || !reported else { return false }
        (self.height, self.width, self.overlay, reported) = (next.0, next.1, next.2, true)
        return true
    }
}
