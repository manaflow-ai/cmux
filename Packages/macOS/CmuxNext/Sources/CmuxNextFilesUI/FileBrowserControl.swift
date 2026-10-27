import AppKit
import CmuxNextDesign

/// The column layout's `NSBrowser`: hands unused keys to the pane.
final class FileBrowserControl: NSBrowser {
    /// Gets keys first; true when used.
    var keyHandler: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    /// The browser makes a scroll view per column, and one that scrolls the columns sideways, as it
    /// lays them out: each takes the shared scrollers, so no bar draws a track (SCROLLBARS-THIN,
    /// Lawrence 2026-10-23 msg 12114).
    override func tile() {
        super.tile()
        followScrollViews(in: self)
    }

    private func followScrollViews(in view: NSView) {
        for subview in view.subviews {
            if let scroll = subview as? NSScrollView, !Self.isFollowed(scroll) {
                // A column scrolls its rows only; the browser's own scroll view scrolls the columns.
                if scroll.hasVerticalScroller, !(scroll.verticalScroller is ThinScroller) { scroll.verticalScroller = ThinScroller() }
                SystemScrollers.follow(scroll)
            }
            followScrollViews(in: subview)
        }
    }

    private static func isFollowed(_ scroll: NSScrollView) -> Bool {
        (!scroll.hasVerticalScroller || scroll.verticalScroller is ThinScroller)
            && (!scroll.hasHorizontalScroller || scroll.horizontalScroller is ThinScroller)
            && scroll.scrollerStyle == SystemScrollers.nativeStyle
    }
}
