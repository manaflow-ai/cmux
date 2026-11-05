public import AppKit
public import CmuxNextDesign

/// FRAME OWNER REFACTOR S3: in a keyboard resize the browser chrome is a container
/// that follows its pane in every frame: its toolbar, progress line and page area lay out at the pane's size, and the
/// page area's own backdrop fills what the page does not. Only the page keeps its size (``BrowserPagePaneMotionHolding``:
/// a Chromium page). A page that cannot hold (a WebKit page, docked DevTools, a side panel, a device fit) keeps the
/// whole chrome held by its pane's content area, as before S3.
extension BrowserChromeView: PaneMotionHoldFollowing {
    public var followsPaneMotion: Bool { (tab.contentView as? any BrowserPagePaneMotionHolding)?.holdsPageInPaneMotion ?? false }

    public func followPaneMotion(_ hold: PaneMotionHold?, heldSize: CGSize?) {
        paneMotionHold = hold
        (tab.contentView as? any BrowserPagePaneMotionHolding)?.holdPage(for: hold)
        needsLayout = true
    }
}
