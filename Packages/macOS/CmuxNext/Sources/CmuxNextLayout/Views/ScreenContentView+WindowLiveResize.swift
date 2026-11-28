import AppKit
import CmuxNextDesign

/// A person's live resize of the whole window (its edge or corner dragged) moves every displayed pane in every tick, so
/// the pane contents follow it as they follow a divider drag (`ScreenContentView+ResizeGesture`), from the window's
/// `viewWillStartLiveResize` to its `viewDidEndLiveResize` (`LayoutRootView+OverlaySync`):
///
/// - the displayed panes' views post no frame notices (``FrameNoticeHold``): a tick's commit skips AppKit's titlebar
///   drag-shape walk, and the Chromium fork's page tracker runs once a page, not once more for each of its ancestors;
///   each moved view posts once at the end;
/// - a Chromium page joins the window's resize fence (`CEFHostView.paneResizeGestureDidChange`): the render server shows
///   each tick with the page's frame at its new size and the main thread waits for nothing;
/// - a terminal asks the grid its new size fits and sends it at most once a refresh (`TerminalHostView+PaneMotion`), the
///   newest at the end.
///
/// Per tick, only what shows lays out (#50672):
///
/// - a pane out of the viewport (a column scrolled past the screen's edge) keeps its old size, out of sight, and lays out
///   once at the end, before its contents hear the end (`applyPresentation`);
/// - a pane whose frame stays below the window's top row tells its content nothing of its window-frame moves (the traffic
///   lights' inset, the top row's line, a hover card) until the end (`PaneHostView.noteWindowFrame(topRowFloor:)`): none
///   of that can change there, and every pane's moved in every tick of a resize from the bottom edge.
///
/// Before this a window resize did none of it: every tick posted every pane view's notice, ran the page tracker
/// synchronously for each page ancestor, and sent each terminal's grid of the size already shown (Leo 2026-11-22:
/// "interior resizing is good and fast. exterior (whole-window of app) resizing is bad").
extension ScreenContentView {
    /// The window's live resize began. Only a person's (a mouse button down on the window's edge, synthetic presses
    /// included): AppKit also starts one for a one-shot frame change (a display change), which lays out once.
    /// `followers`: the pane contents follow it as a divider drag (a person's resize). Off for the chrome's own motion
    /// (``contentAreaMotionBegan()``), whose contents already do what they do in a spring (`NSView.isInPaneMotion`).
    func windowLiveResizeBegan(followers: Bool = true) {
        guard windowResizeListeners == nil, window != nil, !isHiddenOrHasHiddenAncestor, !isParkedOrHasParkedAncestor
        else { return }
        // A divider drag's release still landing hands its contents over to this resize: they hear its end at the end.
        if resizeGesture != .idle { finishResizeGesture() }
        paneFrameNotices.hold(displayedHosts)
        let listeners = followers ? displayedHosts.flatMap { $0.content.paneResizeGestureFollowers() }
            .map { PaneResizeGestureListener(view: $0) } : []
        windowResizeListeners = listeners
        for listener in listeners { listener.view?.paneResizeGestureDidChange(active: true) }
    }

    /// The window's live resize ended: the newest terminal grids go out, each page lays out once at its final size, and
    /// each moved view posts its one frame notice.
    func windowLiveResizeEnded() {
        holdsForContentAreaMotion = false
        guard let listeners = windowResizeListeners else { return }
        windowResizeListeners = nil
        // The panes kept out of sight at their old size take their final one, before their contents hear the end.
        if deferredOffscreenLayout {
            deferredOffscreenLayout = false
            applyPresentation()
        }
        // The window-frame moves held from contents below the top row reach them once.
        for host in displayedHosts { host.flushDeferredWindowFrame() }
        for listener in listeners { listener.view?.paneResizeGestureReleased() }
        for listener in listeners { listener.view?.paneResizeGestureDidChange(active: false) }
        releasePaneFrameNoticesIfSettled()
    }
}

/// The window's chrome resizing the content area over several frames (the sidebar sliding open or closed,
/// `WindowRootView+ContentAreaMotion`) moves and resizes every displayed pane in every frame, as a person's live resize
/// of the window does, and had none of that resize's per-tick savings: every frame posted every pane view's frame notice
/// (and AppKit's titlebar drag-shape walk in its commit), told every pane's content of its window-frame move (each strip's
/// traffic-light avoidance, the window's avoiders), and laid out panes scrolled out of the viewport. The motion now
/// takes the same mode, without the drag followers: its contents keep what they do in a spring (a terminal holds its
/// grid to the landing, `NSView.isInPaneMotion`), so nothing they show changes.
extension ScreenContentView {
    /// The content area's motion began; nothing when a person's live resize already holds this screen.
    func contentAreaMotionBegan() {
        guard windowResizeListeners == nil else { return }
        windowLiveResizeBegan(followers: false)
        holdsForContentAreaMotion = windowResizeListeners != nil
    }

    /// The content area's motion landed (its layout at the final width is in): the end of the mode it started.
    func contentAreaMotionEnded() {
        guard holdsForContentAreaMotion else { return }
        windowLiveResizeEnded()
    }
}
