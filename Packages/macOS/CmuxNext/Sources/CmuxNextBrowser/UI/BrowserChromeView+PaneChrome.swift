public import AppKit
public import CmuxNextDesign

// A browser pane has one rounded content area, as a terminal pane does: the
// pane's tab strip is its header, and the toolbar, bookmarks bar and page all
// sit inside the area the pane rounds and outlines (`PaneContentView`). The
// page is square and flush under the toolbar; it is not a second rounded box.
extension BrowserChromeView: PaneContentChrome {
    /// The toolbar rows are inside the pane's content area, not a header.
    public var paneHeaderHeight: CGFloat { 0 }

    /// The pane rounds its content area around this whole view; the page
    /// area keeps square corners. A Chromium page reads the pane's rounded
    /// clip (`CEFClipShape.clips(around:)`), which cuts only its bottom corners.
    public func setPaneContentCornerRadius(_ radius: CGFloat) {}
}
