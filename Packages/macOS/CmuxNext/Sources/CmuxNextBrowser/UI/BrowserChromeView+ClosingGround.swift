public import AppKit
public import CmuxNextDesign

/// CLOSE MOTION 2 case 3 (cmux-ad m48): this chrome's layer paints the window's color under the page, so a page pane
/// that closes would show the window's color where its page was. Its closing ground is what the page area shows, read
/// once when the pane closes: the error page or the sad tab when one covers the page (CLOSE GROUND FIX: the document
/// under them has its own color), else the shown page's (``BrowserTab/pageGround``); nil keeps the chrome's.
extension BrowserChromeView: PaneGroundReporting {
    public var paneGround: CGColor? { pageStatus.coveringGround ?? tab.pageGround }
}
