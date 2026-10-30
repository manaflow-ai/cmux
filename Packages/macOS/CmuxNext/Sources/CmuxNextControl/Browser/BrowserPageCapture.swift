/// What a `browser.page.screenshot` covers.
public enum BrowserPageCapture: Sendable, Hashable {
    /// What the tab shows.
    case viewport
    /// The whole document.
    case fullPage
    /// Part of the viewport (an element scrolled into view).
    case clip(BrowserPageClip)
}

/// A viewport rectangle in CSS pixels, with the viewport's CSS size so the
/// engine can map it onto the pixels of its viewport snapshot.
public struct BrowserPageClip: Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var viewportWidth: Double
    public var viewportHeight: Double

    public init(x: Double, y: Double, width: Double, height: Double, viewportWidth: Double, viewportHeight: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
    }
}
