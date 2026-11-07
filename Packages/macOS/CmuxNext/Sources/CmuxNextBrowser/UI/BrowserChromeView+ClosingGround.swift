public import AppKit
public import CmuxNextDesign

/// CLOSE MOTION 2 case 3 (cmux-ad m48): this chrome's layer paints the window's color under the page, so a page pane
/// that closes would show the window's color where its page was. Its closing ground is the shown page's own background
/// (``BrowserTab/pageGround``), read once when the pane closes; nil keeps the chrome's.
extension BrowserChromeView: PaneGroundReporting {
    public var paneGround: CGColor? { tab.pageGround }
}
