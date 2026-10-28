import AppKit
import CmuxNextDesign

/// Strip pans at O(1) per input event (behind `motion.renderServer`). The strip's
/// hosts and dividers sit in the strip container (`StripClipContainerView`, the motion container), and
/// their rings and dims in its companion plane (`StripChromePlane`); a pan event sets the translation of
/// the two layers and nothing else: no host, divider or ring frame, no layout, no overlay sync, no
/// tracking area, no display frame. Their frames commit once, at the gesture's end, at the offset it
/// springs to, and the fling is a render-server spring of the translation from where the strip shows,
/// with the release velocity. Pointer input lands the strip where it shows before any view reads it
/// (``landStripWhereItShows()``). Chrome's model: the compositor scrolls the layer per input event and
/// the main thread commits at its next frame (`cc/input/threaded_input_handler.cc`), and a fling is a
/// compositor animation (`cc/input/scroll_offset_animations_impl.h`).
///
/// While the finger is down and during the fling, what reads a pane's window frame and is not pointer
/// input (the tab strip's traffic-light inset, a hovered tab under a still pointer) keeps the laid-out
/// place; it catches up at the fling's start and at its landing.
extension ScreenContentView {
    // MARK: Placement

    /// Whether the strip's dividers sit in the strip container with its hosts, so the pan moves them
    /// too: `motion.renderServer` on, not a canvas (its camera is this view's bounds).
    var dividersInStripContainer: Bool { context.rendersMotionOnServer() && !isCanvas }

    /// Where the divider `kind` sits: the strip container for a strip divider while `inContainer`, in the
    /// container of its row or scroll area there (``scrollerContainer(of:)``).
    func dividerParent(for kind: DividerHandleView.Kind, inContainer: Bool) -> NSView {
        guard inContainer, scrolls(kind) else { return self }
        return scrollerContainer(of: kind) ?? stripContainer
    }

    /// `view`'s frame where it is placed in this view's coordinates, the pan translations included
    /// (``panTranslation(of:)``: the model's, what shows while the finger is down; during a fling the
    /// render server shows more, `StripClipContainerView.shown`).
    func placedFrame(of view: NSView) -> CGRect {
        let moved = panTranslation(of: view)
        return view.frame.offsetBy(dx: moved.dx, dy: moved.dy)
    }

    // MARK: The pan

    /// The container can carry this screen's pan: the strip's dividers are in it with its hosts, and
    /// nothing reads the strip's geometry from frames while it shows moved. Not with a scroll area whose
    /// hosts are clipped one by one (a mask in the camera's coordinates; with its own container,
    /// `ScrollerPanContainerView`, the clip moves with the strip), a zoom (it lifts the container),
    /// a docked column (the rings' dock covers stay where the dock is, which the rings' plane would move
    /// from), floating panes (the window's shade cuts the cards from frames) or content in child windows
    /// (a Chromium page window is placed from its host's frame).
    var pansOnContainer: Bool {
        stripDividersInContainer && geometry.isColumns && geometry.dock.isEmpty
            && baseGeometry.scrollAreas.keys.allSatisfy { scrollerContainer(.area($0)) != nil }
            && zoomMotion.pane == nil && !stripContainer.isLifted && !context.style.floatingPanes
            && !context.childWindowContentShows()
    }

    /// The strip offset the hosts and dividers are laid out at (``panBase`` during a pan on the
    /// container, else the camera's resting value).
    var layoutOffset: CGFloat { panBase ?? scrollState.spring.value }

    /// The camera offset the strip container shows: during a resampled pan on it, the offset its last
    /// frame showed (``ColumnScrollState/presentedPan``), else the camera. Every presentation reads
    /// this, so a frame's spring step never puts the real offset back over the resampled one.
    var shownCameraOffset: CGFloat {
        guard scrollState.resamplesPan, panBase != nil, let pan = scrollState.presentedPan else { return scrollState.spring.value }
        return pan
    }

    /// Shows a pan event on the strip container: its translation (and its rings' plane's) moves to the
    /// camera it shows (``shownCameraOffset``); the pan's first event takes the offset the views are
    /// laid out at as its base. No display frame and no overlay sync is asked for: the rings move with
    /// the translation, and nothing else the overlay sync places moves.
    /// Returns false when the container cannot carry it (``pansOnContainer``).
    func presentPanOnContainer() -> Bool { // perf-hot: 0.3ms motion-frame
        guard pansOnContainer else { return false }
        let base = panBase ?? laidOutStripOffset
        panBase = base
        stripContainer.setTranslation(geometry.viewShift(offset: shownCameraOffset) - geometry.viewShift(offset: base))
        updateScrollbar()
        if !userMotionActive {
            userMotionActive = true
            context.userMotionStepped()
        }
        return true
    }

    /// Ends a pan on the container at the gesture's end with a fling on the render server: the
    /// camera rests on the fling's target, the views lay out there once, and the translation (of the
    /// container and its rings' plane) springs from where the strip shows (a resampled pan shows a little
    /// behind the camera) to zero with the release velocity.
    /// Returns false, changing nothing, when the spring would not animate here; the CPU steps it then.
    func startPanFling() -> Bool {
        let spring = Motion.panes.renderSpring(.scroll)
        guard spring.animates(StripClipContainerView.translationKey.path, in: stripContainer) else { return false }
        let camera = scrollState.spring
        let displacement = stripContainer.translation + geometry.viewShift(offset: layoutOffset) - geometry.viewShift(offset: camera.target)
        scrollState.spring.snap()
        panBase = nil
        // The fling first: the layout pass below then leaves the translation to it.
        stripContainer.startFling(from: displacement, velocity: -camera.velocity, spring: spring) { [weak self] in
            self?.panFlingLanded()
        }
        applyPresentation()
        return true
    }

    /// The camera as it shows during a fling: the target the reducer rests on, less the translation
    /// the render server shows now.
    var flingCamera: SpringValue {
        var camera = scrollState.spring
        let shown = stripContainer.shown
        camera.value = layoutOffset - shown.translation
        camera.velocity = -shown.velocity
        return camera
    }

    /// Takes the camera from a fling on the render server where it shows, with its velocity: the
    /// reducer's spring goes on from there toward the same target on the CPU. The views stay laid out
    /// at the fling's target, held by the container's translation, until the next layout pass places
    /// them at the camera. The fling's leading-column report is owed at the CPU spring's rest.
    func takeCameraFromServer() {
        guard stripContainer.fling != nil else { return }
        let camera = flingCamera
        let layout = layoutOffset
        stripContainer.stopFling()
        scrollState.spring = camera
        panBase = layout
        reportScrollOnSettle = true
        context.requestFrames()
    }

    /// Lays the strip out where it shows, now, before pointer input reaches a view: a press, a pointer
    /// move, a new scroll gesture or a wheel notch while the strip shows moved
    /// (`LayoutRootView.landStripsWhereTheyShow()`). AppKit hit tests, converts the event's point,
    /// and keeps tracking areas and cursor rects at the views' frames, which ignore the translation;
    /// after this the translation is zero and they agree with what shows. Chrome also targets input on
    /// committed geometry, and a press there cancels a fling (`content/browser/renderer_host/input/
    /// fling_controller.cc`); here the fling goes on from where it shows on the CPU
    /// (``takeCameraFromServer()``), which moves the frames, so the strip still rests on a snap point.
    /// A row or scroll area pan on its container lands with it (``landScrollerPans()``).
    func landStripWhereItShows() {
        guard showsPanMoved else { return }
        takeCameraFromServer()
        panBase = nil
        landScrollerPans()
        applyPresentation()
    }

    /// A fling rested: the views are already there. What waits for the landing runs now: the leading
    /// column report (`strip`: the strip's fling, not a row's or scroll area's), the end of the user
    /// motion once no fling runs, divider hover, the overlay and a frame for the visibility of where it
    /// landed.
    func panFlingLanded(strip: Bool = true) {
        if strip { reportLeadingColumn() }
        if userMotionActive, !isGesturing, renderSpringsInFlight == 0, !panFlingsInFlight {
            userMotionActive = false
            if !hasMotion { context.userMotionEnded() }
        }
        refreshDividerHover()
        context.overlayNeedsSync()
        context.requestFrames()
    }

    /// Lands every fling at once (the workspace hides): the views are at their targets already.
    func finishPanFling() {
        let strip = stripContainer.fling != nil
        let scrollers = scrollerContainers.values.filter { $0.fling != nil }
        guard strip || !scrollers.isEmpty else { return }
        if strip { stripContainer.setTranslation(0) }
        for container in scrollers { container.setTranslation(.zero) }
        panFlingLanded(strip: strip)
    }

    // MARK: Visibility

    /// Records how far the strip can pan from where it shows before a pane enters or leaves the
    /// viewport or the keep-alive band (`LayoutRootView.updateVisibility`, after each pass), from the
    /// strip panes' `sweeps`, the rects that pass read (``displayedSweeps()``).
    func recordVisibilitySpan(_ sweeps: [PaneID: CGRect]) {
        let frames = sweeps.compactMap { pane, sweep -> CGRect? in geometry.scrolls(pane: pane) ? sweep : nil }
        visibilitySpan = (stripShift, PanVisibilitySpan(frames: frames, rects: [uncoveredRect, bounds.insetBy(dx: -bounds.width, dy: 0)]))
    }

    /// Whether the strip panned within the recorded span: the visibility pass would report nothing. Never
    /// while a spring moves frames, a camera or a render-server spring under the span: each pan event then
    /// runs the pass.
    var panKeepsVisibility: Bool {
        guard let visibilitySpan, stripContainer.fling == nil, renderTracks.panes.isEmpty, !hasMotion else { return false }
        return visibilitySpan.span.contains(stripShift - visibilitySpan.shift)
    }
}
