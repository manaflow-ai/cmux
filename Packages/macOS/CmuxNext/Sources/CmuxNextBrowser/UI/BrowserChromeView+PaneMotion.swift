public import AppKit
public import CmuxNextDesign

/// FRAME OWNER REFACTOR S3: in a keyboard resize the browser chrome is a container
/// that follows its pane in every frame: its toolbar, progress line and page area lay out at the pane's size, and the
/// page area's own backdrop fills what the page does not. A Chromium page keeps its size, or with S5 lays out at the page
/// area in every frame (``BrowserPagePaneMotionHolding``); a WebKit page always lays out at the page area in every frame
/// (`WebKitPageContainer+PaneMotion`). A page that cannot do either keeps the whole chrome held by its pane's content area,
/// as before S3.
extension BrowserChromeView: PaneMotionHoldFollowing {
    public var followsPaneMotion: Bool { (tab.contentView as? any BrowserPagePaneMotionHolding)?.holdsPageInPaneMotion ?? false }

    public func followPaneMotion(_ hold: PaneMotionHold?, heldSize: CGSize?) {
        paneMotionHold = hold
        (tab.contentView as? any BrowserPagePaneMotionHolding)?.holdPage(for: hold)
        needsLayout = true
    }
}

/// A layout change that shows in one commit (a split, a close, a zoom, an unzoom) asks the shown page whether it takes
/// part in that commit: a Chromium page does (``CEFTabContentView`` as ``PaneCommitSurface``), so the frame that shows
/// the change shows the page's own frame at its new size, not its old frame beside its backdrop. A WebKit page and a
/// page that shows no Chromium content take no part.
extension BrowserChromeView: PaneCommitSurfaceHosting {
    public var commitSurfaces: [any PaneCommitSurface] {
        guard let page = tab.contentView as? any PaneCommitSurface, page.superview != nil, !page.isHidden else { return [] }
        return [page]
    }
}
