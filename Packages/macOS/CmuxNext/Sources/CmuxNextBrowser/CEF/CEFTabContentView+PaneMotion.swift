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
            // A split's or close's spring this key resize caught left its motion to this landing (``endPaneSpring()``):
            // after the landing's layout, the page window comes back once, at the final size. Nothing when no spring ran.
            if pageSyncReasons.isEmpty { paneMotion(active: false) }
            return
        }
        endRestHold()
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
            pageRestHold = false
            guard let hosting = motionHosting else { return }
            motionHosting = nil
            hosting.resizeMotion(active: false)
        }
    }

    /// A drag or a key resize caught a spring whose page waits at its rest: it follows its pane from now on, and that
    /// motion's end lands it.
    func endRestHold() {
        guard pageRestHold else { return }
        pageRestHold = false
        dropHold()
    }
}

/// A split's, close's or zoom's spring resizes the pane in every frame, as a key resize does (Leo 2026-11-07, softened: a
/// close beside a page "first shifts over to the left ... And then after the shift, then it expands. It's not, like,
/// expanding as it goes"). Only drags and key resizes took the page window out of the motion's way, so in a split or a
/// close each frame moved and resized an attached child window through the WindowServer, Chromium's frames at the new
/// sizes came after the pane had moved, and the page's last frame slid with the pane's edge until they did. The spring's
/// start (`PaneHostView.announceRest`, once per start or retarget) begins the key resize's motion here: the page follows
/// its pane's page area at each frame's size with its window detached (``paneMotion(active:)``), and the landing
/// (``paneMotionDidSettle()``) lays it out at the final size and brings the window back once. The main thread never waits
/// for a page frame (the page sync's deadline stays 0).
///
/// A page that holds the keys keeps its window (#37755: a close hands the keys to the page beside the closing pane, in the
/// close's own turn, before the spring's first frame). Ordering a key window out moves the keys, an AppKit key change
/// (#24913), and an attached window resized in every frame is the shift-then-expand. So that page lays out once, at the
/// size it rests at, when the spring starts, and keeps that size to the landing (``holdPageAtRest(_:)``): its pixels, in
/// the window's own layers, ride the pane's top-left corner, clipped by the pane, beside the page's own backdrop while the
/// pane is larger. Its window takes one size in the motion and its keys, first responder and focus ask stay as they were.
extension CEFTabContentView: PaneMotionTargeting {
    func paneMotionWillRest(sizeChange: CGSize) -> PaneMotionAnchor {
        // A drag (its release spring included) and a key resize run their own motion, begun before the spring's rest.
        guard window != nil, pageSyncReasons.isDisjoint(with: [.drag, .keyResize]), pageMotionHold == nil else { return .top }
        paneMotion(active: true)
        // Decided at the spring's start (a retarget keeps the choice): the page that keeps its window waits at its rest.
        if pageRestHold || (!pageSyncReasons.contains(.paneSpring) && motionHosting?.keepsWindowInMotion == true) {
            let rest = CGSize(width: bounds.width + sizeChange.width, height: bounds.height + sizeChange.height)
            if holdPageAtRest(rest) {
                pageRestHold = true
                return .top
            }
            // It cannot hold (DevTools docked, a side panel, a fit): it follows its pane, as before.
            endRestHold()
        }
        beginPageSync(.paneSpring)
        return .top
    }

    /// The spring landed: the page lays out at the final size, then its window comes back, once. A drag or key resize that
    /// caught the spring ends the motion itself.
    func endPaneSpring() {
        if pageRestHold {
            // The page is at its rest size already: the landing's layout places it on the page area, with no resize.
            endRestHold()
            layoutContent()
            paneMotion(active: false)
            return
        }
        guard pageSyncReasons.contains(.paneSpring) else { return }
        endPageSync(.paneSpring)
        guard pageSyncReasons.isEmpty, pageMotionHold == nil else { return }
        layoutContent()
        paneMotion(active: false)
    }
}

/// A split's, close's or zoom's spring resizes the pane in every frame, as a key resize does (Leo 2026-11-07, softened: a
/// close beside a page "first shifts over to the left ... And then after the shift, then it expands. It's not, like,
/// expanding as it goes"). Only drags and key resizes took the page window out of the motion's way, so in a split or a
/// close each frame moved and resized an attached child window through the WindowServer, Chromium's frames at the new
/// sizes came after the pane had moved, and the page's last frame slid with the pane's edge until they did. The spring's
/// start (`PaneHostView.announceRest`, once per start or retarget) begins the key resize's motion here: the page follows
/// its pane's page area at each frame's size with its window detached (``paneMotion(active:)``), and the landing
/// (``paneMotionDidSettle()``) lays it out at the final size and brings the window back once. The main thread never waits
/// for a page frame (the page sync's deadline stays 0).
extension CEFTabContentView: PaneMotionTargeting {
    func paneMotionWillRest(sizeChange: CGSize) -> PaneMotionAnchor {
        // A drag (its release spring included) and a key resize run their own motion, begun before the spring's rest.
        guard window != nil, pageSyncReasons.isDisjoint(with: [.drag, .keyResize]), pageMotionHold == nil else { return .top }
        paneMotion(active: true)
        beginPageSync(.paneSpring)
        return .top
    }

    /// The spring landed: the page lays out at the final size, then its window comes back, once. A drag or key resize that
    /// caught the spring ends the motion itself.
    func endPaneSpring() {
        guard pageSyncReasons.contains(.paneSpring) else { return }
        endPageSync(.paneSpring)
        guard pageSyncReasons.isEmpty, pageMotionHold == nil else { return }
        layoutContent()
        paneMotion(active: false)
    }
}
