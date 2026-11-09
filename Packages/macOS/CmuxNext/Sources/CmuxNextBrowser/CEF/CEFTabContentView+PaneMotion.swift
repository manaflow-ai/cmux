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
/// the pane clips it, and this
/// view paints the page's own backdrop beside it, never the shell (the drag hold's path, `startPageHold`). It lays out
/// once when the hold ends, before the pane hears that the motion landed. A page that cannot hold any longer (DevTools
/// docked, a side panel or a fit came up, the tab was hidden mid-hold) lays out live at the chrome's page area, as a page
/// does in a split or close spring: never the shell, the chrome's own page area is beside it. A page hidden and shown again
/// during the hold holds again (`resumePageHold`).
///
/// With FRAME OWNER S5 (cmux-ad m14, the only path since 2026-11-06) a key resize holds nothing: the page
/// follows its pane's page area in every frame, at that frame's size, hosted in the window's layers, with no main-thread wait
/// for its frame (`beginPageSync(.keyResize)`, `CEFTabContentView+PageSync`) until the hold ends. A page that places itself
/// (docked DevTools, a side panel, a fit) follows too, with geometry only per frame: its tab container sets each view's
/// frame once, with the occlusion set first, so each page window gets one tracker update (STATUS 13849, m18).
extension CEFTabContentView: BrowserPagePaneMotionHolding {
    var holdsPageInPaneMotion: Bool {
        pageMotionHold != nil || canStartPageHold || (window != nil && tab != nil)
    }

    /// This key hold's page follows its pane (S5) instead of holding its size.
    private var pageFollowsPane: Bool { pageSyncReasons.contains(.keyResize) }

    /// Shown again during its pane's key hold (a tab switch away and back): it holds its page again, at the size the page
    /// has now; one that cannot lays out live, as it would at the hold's start.
    func resumePageHold() {
        guard pageMotionHold != nil, heldPageSize == nil, !pageFollowsPane else { return }
        if startPageHold() { needsLayout = true } else { pageMotionHold = nil }
    }

    /// The page window stays attached through the hold (RESIZE P0 5): only a divider drag detaches it (``paneMotion(active:)``).
    func holdPage(for hold: PaneMotionHold?) {
        guard let hold else {
            endPageSync(.keyResize)
            if pageMotionHold != nil {
                dropHold()
                layoutContent()
            }
            return
        }
        if pageMotionHold == nil {
            // S5: no hold. The page lays out at the page area in every frame (no main-thread wait for its frame).
            beginPageSync(.keyResize)
        }
        if pageFollowsPane {
            pageMotionHold = hold
            needsLayout = true
            return
        }
        // A drag's own hold, or a page that cannot hold (DevTools docked, a side panel, a fit), lays out as before.
        if pageMotionHold == nil {
            guard startPageHold() else { return }
            pageHoldTopLeft = true
        }
        pageMotionHold = hold
        needsLayout = true
    }
}

extension CEFTabContentView {
    /// A divider drag of this container's pane began (its press) or landed: the shown page's window detaches for it unless
    /// the page holds the keys (``CEFLayerHosting/resizeMotion(active:)``). A key resize keeps the page attached (RESIZE P0
    /// 5, cmux21 120 Hz: detached, its spring's first tick paid the detach, 1-4 ms, and a page in a pane that grew upward
    /// showed at its old place for about 25 frames; attached, it showed at its pane's size in every frame with the same
    /// missed refreshes). One share per container; a start while one is held and an end with none are ignored.
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

/// A split's, close's or zoom's spring resizes the pane in every frame, as a key resize does: the spring's start
/// (`PaneHostView.announceRest`, once per start or retarget) begins the key resize's page sync, so the page follows its
/// pane's page area at each frame's size, and the landing (``paneMotionDidSettle()``) lays it out at the final size. The
/// page window stays attached, as in a key resize (RESIZE P0 5). Detached for the spring (#37754), a page in a pane that
/// grew upward showed at its old place, clipped or blank, until a one-frame snap at the landing (Leo 2026-11-08,
/// ask-1cbd6386ac, softened: "the upwards thing ... shit doesn't look right, shit is not smooth, shit lags"; the same
/// 25-frame stale page RESIZE P0 5 filmed for detached key resizes). The main thread never waits for a page frame (the
/// page sync's deadline stays 0).
extension CEFTabContentView: PaneMotionTargeting {
    func paneMotionWillRest(sizeChange: CGSize) -> PaneMotionAnchor {
        // A drag (its release spring included) and a key resize run their own motion, begun before the spring's rest.
        guard window != nil, pageSyncReasons.isDisjoint(with: [.drag, .keyResize]), pageMotionHold == nil else { return .top }
        beginPageSync(.paneSpring)
        return .top
    }

    /// The spring landed: the page lays out at the final size, once. A drag or key resize that caught the spring ends the
    /// motion itself.
    func endPaneSpring() {
        guard pageSyncReasons.contains(.paneSpring) else { return }
        endPageSync(.paneSpring)
        guard pageSyncReasons.isEmpty, pageMotionHold == nil else { return }
        layoutContent()
    }
}
