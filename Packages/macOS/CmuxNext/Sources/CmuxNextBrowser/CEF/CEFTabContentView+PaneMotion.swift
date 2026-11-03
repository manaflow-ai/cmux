import AppKit
import CmuxNextDesign

/// A tab's page view that keeps its size through a keyboard resize's hold while the browser chrome around it follows its
/// pane (FRAME OWNER REFACTOR S3, ``BrowserChromeView`` as ``PaneMotionHoldFollowing``).
@MainActor
protocol BrowserPagePaneMotionHolding: NSView {
    /// Whether the page holds through a key hold now, or could start one (a plain page in a window).
    var holdsPageInPaneMotion: Bool { get }
    /// The pane's hold began or changed its edges (the page keeps its size on them), or ended (nil: it lays out once).
    func holdPage(for hold: PaneMotionHold?)
}

/// A Chromium page draws in another process, some frames after its window takes a size: through a key resize the page
/// keeps the size it had when the hold began, fixed at the pane edges that do not move, the pane clips it, and this
/// view paints the page's own backdrop beside it, never the shell (the drag hold's path, `startPageHold`). It lays out
/// once when the hold ends, before the pane hears that the motion landed.
extension CEFTabContentView: BrowserPagePaneMotionHolding {
    var holdsPageInPaneMotion: Bool { pageMotionHold != nil || (heldPageSize == nil && window != nil && pageCanHold) }

    func holdPage(for hold: PaneMotionHold?) {
        guard let hold else {
            guard pageMotionHold != nil else { return }
            dropHold()
            return
        }
        // A drag's own hold, or a page that cannot hold (DevTools docked, a side panel, a fit), lays out as before.
        if pageMotionHold == nil, !startPageHold() { return }
        pageMotionHold = hold
        needsLayout = true
    }
}
