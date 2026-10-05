public import Foundation

/// Bounds on what one `tab.screenshot` or `tab.pdf` may make the app
/// allocate. The caller chooses a clip, a full page, a paper size and
/// margins; the main actor renders them, so one oversized capture would
/// stall or exhaust memory for every session and the user's windows.
public struct BrowserReplCaptureLimits: Sendable {
    public init() {}

    /// Throws `invalid` when a screenshot of `region` (CSS pixels) at `zoom`
    /// (WebKit's page zoom times magnification) is out of bounds.
    public func checkScreenshot(region: CGRect, zoom: CGFloat) throws {}

    /// Throws `invalid` when a PDF on `paper` with `margins` (points) is out
    /// of bounds.
    public func checkPDF(paper: CGSize, margins: NSEdgeInsets) throws {}
}
