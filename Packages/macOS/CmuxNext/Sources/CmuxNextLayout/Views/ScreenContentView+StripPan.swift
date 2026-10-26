import AppKit
import CmuxNextDesign

/// Strip pans at O(1) per input event (p03-rendering-026, behind `motion.renderServer`). The strip's
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

    /// Where the divider `kind` sits: the strip container for a strip divider while `inContainer`.
    func dividerParent(for kind: DividerHandleView.Kind, inContainer: Bool) -> NSView {
        inContainer && scrolls(kind) ? stripContainer : self
    }

    /// The pan translation the layout's model holds for `view` (0 outside the strip container): what
    /// shows of it while the finger is down. During a fling the render server shows more
    /// (`StripClipContainerView.shown`).
    func panTranslation(of view: NSView) -> CGFloat { view.superview === stripContainer ? stripContainer.translation : 0 }

    /// `view`'s frame where it is placed in this view's coordinates, the pan translation included.
    func placedFrame(of view: NSView) -> CGRect { view.frame.offsetBy(dx: panTranslation(of: view), dy: 0) }

    // MARK: The pan

    /// The container can carry this screen's pan: the strip's dividers are in it with its hosts, and
    /// nothing reads the strip's geometry from frames while it shows moved. Not with a scroll area (an
    /// area's window clips its hosts in the camera's coordinates), a zoom (it lifts the container),
    /// a docked column (the rings' dock covers stay where the dock is, which the rings' plane would move
    /// from), floating panes (the window's shade cuts the cards from frames) or content in child windows
    /// (a Chromium page window is placed from its host's frame).
    var pansOnContainer: Bool {
        stripDividersInContainer && geometry.isColumns && geometry.dock.isEmpty && baseGeometry.scrollAreas.isEmpty
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
        guard spring.animates(StripClipContainerView.translationKeyPath, in: stripContainer) else { return false }
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
    func landStripWhereItShows() {
        guard stripContainer.showsMoved else { return }
        takeCameraFromServer()
        panBase = nil
        applyPresentation()
    }

    /// The fling rested: the views are already there. What waits for the landing runs now: the
    /// leading column report, the end of the user motion, divider hover, the overlay and a frame for
    /// the visibility of where it landed.
    func panFlingLanded() {
        reportLeadingColumn()
        if userMotionActive, !isGesturing, renderSpringsInFlight == 0 {
            userMotionActive = false
            if !hasMotion { context.userMotionEnded() }
        }
        refreshDividerHover()
        context.overlayNeedsSync()
        context.requestFrames()
    }

    /// Lands a fling at once (the workspace hides): the views are at its target already.
    func finishPanFling() {
        guard stripContainer.fling != nil else { return }
        stripContainer.setTranslation(0)
        panFlingLanded()
    }

    // MARK: Visibility

    /// Records how far the strip can pan from where it shows before a pane enters or leaves the
    /// viewport or the keep-alive band (`LayoutRootView.updateVisibility`, after each pass).
    func recordVisibilitySpan() {
        let shift = stripShift
        let frames = paneFrames.compactMap { pane, frame -> CGRect? in
            geometry.scrolls(pane: pane) ? displayedRect(frame.rect, pane: pane) : nil
        }
        visibilitySpan = (shift, PanVisibilitySpan(frames: frames, rects: [uncoveredRect, bounds.insetBy(dx: -bounds.width, dy: 0)]))
    }

    /// Whether the strip panned within the recorded span: the visibility pass would report nothing.
    var panKeepsVisibility: Bool {
        guard let visibilitySpan, stripContainer.fling == nil else { return false }
        return visibilitySpan.span.contains(stripShift - visibilitySpan.shift)
    }
}
