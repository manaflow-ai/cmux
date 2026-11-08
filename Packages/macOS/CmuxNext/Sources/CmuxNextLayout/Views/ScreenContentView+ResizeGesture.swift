import AppKit
import CmuxNextDesign

/// Where a screen's panes stand on a person's resize drag (``ScreenContentView/resizeGesture``).
enum PaneResizeGesturePhase: Equatable {
    /// No drag: the pane contents follow their frames.
    case idle
    /// A divider or edge moves under the pointer.
    case active
    /// Released; the layout the release makes has not reached this screen yet.
    case releasing
    /// The release's layout is here; its spring, if any, has not landed.
    case landing
}

/// A pane content told about a resize drag, held weakly until it hears the end.
struct PaneResizeGestureListener {
    weak var view: (any PaneResizeGestureFollowing)?
}

/// A person's divider or edge drag, told to the pane contents that follow it their own way
/// (``PaneResizeGestureFollowing``: a Chromium page keeps its size until the pane's frame is final).
/// They hear `true` on the drag's first move (a click on a divider moves nothing and tells nothing)
/// and `false` once the release's layout landed, so a page lays out once, at the pane's final size,
/// not once per frame of the release's spring. The end goes to exactly the contents that heard the
/// start, wherever they are by then (a pane moved to another screen, a screen torn down).
///
/// No timer: the release requests display frames, the end comes from the model sync that applies the
/// release (`LayoutRootView.sync`; a frame tick that finds the sync still pending runs it,
/// `LayoutRootView.advanceFrame`) and the frame its spring lands in (`step`), or at once when motion is
/// settled without frames (Reduce Motion, a hidden screen, a parked or removed workspace, a teardown).
///
/// From the first move to that end, the displayed panes' views post no frame notices (``FrameNoticeHold``):
/// each drag frame's commit then skips AppKit's titlebar drag-shape walk, and each moved view posts once at the end.
extension ScreenContentView {
    func resizeGestureMoved() {
        // A hidden or parked screen steps no frames, so a drag there could not land; its pages lay out as before.
        guard window != nil, !isHiddenOrHasHiddenAncestor, !isParkedOrHasParkedAncestor else { return }
        if resizeGesture == .idle {
            paneFrameNotices.hold(displayedHosts)
            resizeGestureListeners = displayedHosts.flatMap { $0.content.paneResizeGestureFollowers() }
                .map { PaneResizeGestureListener(view: $0) }
            for listener in resizeGestureListeners { listener.view?.paneResizeGestureDidChange(active: true) }
        }
        resizeGesture = .active
    }

    /// The pointer let go (or the drag was cancelled): the contents hear it now; the end waits for the release's landing.
    func resizeGestureReleased() {
        guard resizeGesture == .active else { return }
        resizeGesture = .releasing
        for listener in resizeGestureListeners { listener.view?.paneResizeGestureReleased() }
        context.requestFrames()
    }

    /// `LayoutRootView.sync` applied the model with its gesture flag: once off, the release's layout is in this screen.
    func resizeGestureModelSynced(gestureActive: Bool) {
        guard resizeGesture == .releasing, !gestureActive else { return }
        resizeGesture = .landing
        finishResizeGestureIfLanded()
    }

    /// The end, once the release's layout is here and no pane or divider moves (every frame of this
    /// screen, `step`, and each sync).
    func finishResizeGestureIfLanded() {
        guard resizeGesture == .landing, !hasMotion else { return }
        finishResizeGesture()
    }

    /// A screen going away: its listeners, to hand to the screen their panes moved to
    /// (`LayoutRootView.sync`), without telling them anything.
    func takeResizeGestureListeners() -> [PaneResizeGestureListener] {
        paneFrameNotices.release()
        guard resizeGesture != .idle else { return [] }
        let listeners = resizeGestureListeners
        resizeGesture = .idle
        resizeGestureListeners = []
        return listeners
    }

    /// Listeners whose panes came here from a screen that went away: they hear the end when this
    /// screen's layout lands (with its own drag, when one is under way).
    func adoptResizeGestureListeners(_ listeners: [PaneResizeGestureListener]) {
        guard !listeners.isEmpty else { return }
        // A hidden or parked screen steps no frames and lands nothing: they lay out now.
        guard window != nil, !isHiddenOrHasHiddenAncestor, !isParkedOrHasParkedAncestor else {
            for listener in listeners { listener.view?.paneResizeGestureDidChange(active: false) }
            return
        }
        resizeGestureListeners += listeners
        if resizeGesture == .idle { resizeGesture = .landing }
        context.requestFrames()
    }

    /// Gives the pane views their frame notices back once no resize drag and no zoom moves them (``FrameNoticeHold``).
    func releasePaneFrameNoticesIfSettled() {
        guard resizeGesture == .idle, zoomMotion.pane == nil, paneFrameNotices.isHolding else { return }
        paneFrameNotices.release()
    }

    /// Tells the contents that heard the start that the drag is over, now.
    func finishResizeGesture() {
        // Each pane view the drag moved posts its one frame notice now (a zoom still on its spring keeps them).
        defer { releasePaneFrameNoticesIfSettled() }
        guard resizeGesture != .idle else { return }
        resizeGesture = .idle
        let listeners = resizeGestureListeners
        resizeGestureListeners = []
        for listener in listeners { listener.view?.paneResizeGestureDidChange(active: false) }
    }
}
