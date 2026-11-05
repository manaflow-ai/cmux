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
/// keeps the size it had when the hold began, never scaled, with its top-left corner on the page area's (cmux-ad m6 1b,
/// `BrowserResizeTunables.keyResizeTopLeft`; off: fixed at the pane edges that do not move), the pane clips it, and this
/// view paints the page's own backdrop beside it, never the shell (the drag hold's path, `startPageHold`). It lays out
/// once when the hold ends, before the pane hears that the motion landed. A page that cannot hold any longer (DevTools
/// docked, a side panel or a fit came up, the tab was hidden mid-hold) lays out live at the chrome's page area, as a page
/// does in a split or close spring: never the shell, the chrome's own page area is beside it. A page hidden and shown again
/// during the hold holds again (`resumePageHold`).
extension CEFTabContentView: BrowserPagePaneMotionHolding {
    var holdsPageInPaneMotion: Bool { pageMotionHold != nil || canStartPageHold }

    /// Shown again during its pane's key hold (a tab switch away and back): it holds its page again, at the size the page
    /// has now; one that cannot lays out live, as it would at the hold's start.
    func resumePageHold() {
        guard pageMotionHold != nil, heldPageSize == nil else { return }
        if startPageHold() { needsLayout = true } else { pageMotionHold = nil }
    }

    func holdPage(for hold: PaneMotionHold?) {
        guard let hold else {
            guard pageMotionHold != nil else { return paneMotion(active: false) }
            dropHold()
            // The landing's layout first, so the page window comes back once, at the final size.
            layoutContent()
            paneMotion(active: false)
            return
        }
        paneMotion(active: true)
        // A drag's own hold, or a page that cannot hold (DevTools docked, a side panel, a fit), lays out as before.
        if pageMotionHold == nil {
            guard startPageHold() else { return }
            pageHoldTopLeft = BrowserResizeTunables.keyResizeTopLeft.value // latched for this hold
        }
        pageMotionHold = hold
        needsLayout = true
    }
}

extension CEFTabContentView {
    /// A resize motion of this container's pane began (a divider drag's press, a key resize's first press) or landed:
    /// the shown page's window detaches for it unless the page holds the keys (``CEFLayerHosting/resizeMotion(active:)``).
    /// One share per container; a start while one is held and an end with none are ignored.
    func paneMotion(active: Bool) {
        if active {
            guard motionHosting == nil, window != nil, let tab, tab.host.hostView.superview === self else { return }
            let hosting = tab.host.hostView.layerHosting
            motionHosting = hosting
            hosting.resizeMotion(active: true)
        } else {
            guard let hosting = motionHosting else { return }
            motionHosting = nil
            hosting.resizeMotion(active: false)
        }
    }
}
