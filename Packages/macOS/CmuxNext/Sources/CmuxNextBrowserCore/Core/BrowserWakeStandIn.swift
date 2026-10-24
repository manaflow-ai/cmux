public import CoreGraphics

/// A page that can show a woken (hibernated) tab's last picture over itself
/// until it paints, so a wake looks instant. Chromium pages adopt it while
/// layer hosted (`CEFTab`); a page that cannot returns false and the caller
/// keeps its own stand-in until the page is made.
@MainActor
public protocol BrowserWakeStandIn: AnyObject {
    /// Shows `image` over the page until the page paints its first content,
    /// its pane shows another tab, or `cap` passes.
    ///
    /// - Parameters:
    ///   - image: the tab's picture from when it went to sleep.
    ///   - cap: the longest it shows when the page never paints.
    /// - Returns: whether the picture shows.
    func showWakeStandIn(_ image: CGImage, cap: Duration) -> Bool
}
