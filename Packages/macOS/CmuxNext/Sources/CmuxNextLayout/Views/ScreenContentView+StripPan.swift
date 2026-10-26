import AppKit
import CmuxNextDesign

/// Strip pans at O(1) per input event (p03-rendering-026, behind `motion.renderServer`). The strip's
/// hosts and dividers sit in the strip container (`StripClipContainerView`, the motion container); a
/// pan event sets its translation and nothing else: no host or divider frame, no layout, no tracking
/// area, no display frame. Their frames commit once, at the gesture's end, at the offset it springs
/// to, and the fling is a render-server spring of the translation from where the strip shows, with the
/// release velocity. Chrome's model: the compositor scrolls the layer per input event and the main
/// thread commits at its next frame (`cc/input/threaded_input_handler.cc`), and a fling is a compositor
/// animation (`cc/input/scroll_offset_animations_impl.h`).
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
    /// shows of it while the finger is down. During a fling the overlay springs with it instead.
    func panTranslation(of view: NSView) -> CGFloat { view.superview === stripContainer ? stripContainer.translation : 0 }

    /// `view`'s frame where it is placed in this view's coordinates, the pan translation included.
    func placedFrame(of view: NSView) -> CGRect { view.frame.offsetBy(dx: panTranslation(of: view), dy: 0) }

    /// `windowPoint` moved to where `view`'s ancestors under the strip container are laid out: what
    /// `convert(_:from: nil)` needs to hit `view` where it shows.
    func laidOutWindowPoint(_ windowPoint: NSPoint, for view: NSView) -> NSPoint {
        view.isDescendant(of: stripContainer) ? stripContainer.laidOutWindowPoint(windowPoint) : windowPoint
    }

    // MARK: The pan

    /// The container can carry this screen's pan: the strip's dividers are in it with its hosts, with
    /// no scroll area (an area's window clips its hosts in the camera's coordinates) and no zoom (it
    /// lifts the container).
    var pansOnContainer: Bool {
        stripDividersInContainer && geometry.isColumns && baseGeometry.scrollAreas.isEmpty && zoomMotion.pane == nil
            && !stripContainer.isLifted
    }

    /// The strip offset the hosts and dividers are laid out at (``panBase`` during a pan on the
    /// container, else the camera's resting value).
    var layoutOffset: CGFloat { panBase ?? scrollState.spring.value }

    /// Shows a pan event on the strip container: its translation moves to the camera, one layer
    /// property; the pan's first event takes the offset the views are laid out at as its base. No
    /// display frame is asked for. Returns false when the container cannot carry it (``pansOnContainer``).
    func presentPanOnContainer() -> Bool { // perf-hot: 0.3ms motion-frame
        guard pansOnContainer else { return false }
        let base = panBase ?? laidOutStripOffset
        panBase = base
        stripContainer.setTranslation(geometry.viewShift(offset: scrollState.spring.value) - geometry.viewShift(offset: base))
        updateScrollbar()
        if !userMotionActive {
            userMotionActive = true
            context.userMotionStepped()
        }
        // The rings and dims follow (`LayoutRootView.syncOverlay`), once per run loop turn.
        context.overlayNeedsSync()
        return true
    }

    /// Ends a pan on the container at the gesture's end with a fling on the render server: the
    /// camera rests on the fling's target, the views lay out there once, and the translation (with the
    /// pane rings and dims) springs from where the strip shows to zero with the release velocity.
    /// Returns false, changing nothing, when the spring would not animate here; the CPU steps it then.
    func startPanFling() -> Bool {
        let spring = Motion.panes.renderSpring(.scroll)
        guard spring.animates(StripClipContainerView.translationKeyPath, in: stripContainer) else { return false }
        let camera = scrollState.spring
        let displacement = geometry.viewShift(offset: camera.value) - geometry.viewShift(offset: camera.target)
        scrollState.spring.snap()
        panBase = nil
        let chrome = stripContainer.subviews.compactMap { view -> CALayer? in
            guard let host = view as? PaneHostView, host.chrome.superview != nil else { return nil }
            return host.chrome.layer
        }
        // The fling first: the layout pass below then leaves the translation to it.
        stripContainer.startFling(from: displacement, velocity: -camera.velocity, spring: spring, with: chrome) { [weak self] in
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
        context.overlayNeedsSync()
        context.requestFrames()
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
