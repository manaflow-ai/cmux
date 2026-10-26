import AppKit
import CmuxNextDesign

/// Strip pans at O(1) per input event (p03-rendering-026, behind `motion.renderServer`). The strip's
/// hosts and dividers sit in the motion container (`StripPanContainerView`); a pan event sets its
/// translation and nothing else: no host or divider frame, no layout, no tracking area. Their frames
/// commit once, at the gesture's end, at the offset it springs to, and the fling is a render-server
/// spring of the translation from where the strip shows, with the release velocity. Chrome's model:
/// the compositor scrolls the layer per input event and the main thread commits at its next frame
/// (`cc/input/threaded_input_handler.cc`), and a fling is a compositor animation
/// (`cc/input/scroll_offset_animations_impl.h`).
extension ScreenContentView {
    // MARK: Placement

    /// Whether the strip's hosts and dividers go in the motion container: `motion.renderServer` on, no
    /// docked column (a strip pane's dock clip is per host until p03-rendering-023 makes it layer
    /// structure), not a canvas (its camera is this view's bounds).
    var usesPanContainer: Bool { context.rendersMotionOnServer() && geometry.dock.isEmpty && !isCanvas }

    /// Where `pane`'s host sits: the motion container for a strip pane while `inContainer`, else this
    /// view (a docked pane, the zooming pane, which is above everything until it lands).
    func hostParent(for pane: PaneID, inContainer: Bool) -> NSView {
        inContainer && geometry.scrolls(pane: pane) && pane != zoomMotion.pane ? panContainer : self
    }

    /// Where the divider `kind` sits: the motion container for a strip divider while `inContainer`.
    func dividerParent(for kind: DividerHandleView.Kind, inContainer: Bool) -> NSView {
        inContainer && scrolls(kind) ? panContainer : self
    }

    /// True when this screen places `view`, directly or in the motion container.
    func holds(_ view: NSView) -> Bool { view.superview === self || view.superview === panContainer }

    /// Moves `view` under `parent` (this view or the motion container), keeping the window's first
    /// responder when it is in `view`: a focused pane keeps its keys.
    func move(_ view: NSView, to parent: NSView) {
        let responder = window?.firstResponder as? NSView
        let focused = responder.map { $0.isDescendant(of: view) } ?? false
        parent.addSubview(view)
        if focused, let responder, window?.firstResponder !== responder { window?.makeFirstResponder(responder) }
    }

    /// This view's subviews back to front, the motion container's in its place: the order they draw in.
    var stackedSubviews: [NSView] {
        subviews.flatMap { $0 === panContainer ? panContainer.subviews : [$0] }
    }

    /// The pan translation the layout's model holds for `view` (0 outside the motion container): what
    /// shows of it while the finger is down. During a fling the overlay springs with it instead.
    func panTranslation(of view: NSView) -> CGFloat { view.superview === panContainer ? panContainer.translation : 0 }

    /// `view`'s frame where it is placed in this view's coordinates, the pan translation included.
    func placedFrame(of view: NSView) -> CGRect { view.frame.offsetBy(dx: panTranslation(of: view), dy: 0) }

    /// `windowPoint` moved to where `view`'s ancestors under the motion container are laid out: what
    /// `convert(_:from: nil)` needs to hit `view` where it shows.
    func laidOutWindowPoint(_ windowPoint: NSPoint, for view: NSView) -> NSPoint {
        view.isDescendant(of: panContainer) ? panContainer.laidOutWindowPoint(windowPoint) : windowPoint
    }

    // MARK: The pan

    /// The container can carry this screen's pan: the strip is in it, with no scroll area (an area's
    /// window clips its hosts in the camera's coordinates) and no zoom moving a pane outside it.
    var pansOnContainer: Bool {
        stripInPanContainer && geometry.isColumns && geometry.dock.isEmpty && baseGeometry.scrollAreas.isEmpty
            && zoomMotion.pane == nil
    }

    /// The strip offset the hosts and dividers are laid out at (``panBase`` during a pan on the
    /// container, else the camera's resting value).
    var layoutOffset: CGFloat { panBase ?? scrollState.spring.value }

    /// Shows a pan event on the motion container: its translation moves to the camera, one layer
    /// property; the pan's first event takes the offset the views are laid out at as its base. No
    /// display frame is asked for. Returns false when the container cannot carry it (``pansOnContainer``).
    func presentPanOnContainer() -> Bool { // perf-hot: 0.3ms motion-frame
        guard pansOnContainer else { return false }
        if panBase == nil { panBase = laidOutStripOffset }
        let base = panBase ?? laidOutStripOffset
        panContainer.setTranslation(geometry.viewShift(offset: scrollState.spring.value) - geometry.viewShift(offset: base))
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
        guard spring.animates(StripPanContainerView.translationKeyPath, in: panContainer) else { return false }
        let camera = scrollState.spring
        let displacement = geometry.viewShift(offset: camera.value) - geometry.viewShift(offset: camera.target)
        scrollState.spring.snap()
        panBase = nil
        let chrome = panContainer.subviews.compactMap { view -> CALayer? in
            guard let host = view as? PaneHostView, host.chrome.superview != nil else { return nil }
            return host.chrome.layer
        }
        // The fling first: the layout pass below then leaves the translation to it.
        panContainer.startFling(from: displacement, velocity: -camera.velocity, spring: spring, with: chrome) { [weak self] in
            self?.panFlingLanded()
        }
        applyPresentation()
        return true
    }

    /// The camera as it shows during a fling: the target the reducer rests on, less the translation
    /// the render server shows now.
    var flingCamera: SpringValue {
        var camera = scrollState.spring
        let shown = panContainer.shown
        camera.value = layoutOffset - shown.translation
        camera.velocity = -shown.velocity
        return camera
    }

    /// Takes the camera from a fling on the render server where it shows, with its velocity: the
    /// reducer's spring goes on from there toward the same target on the CPU. The views stay laid out
    /// at the fling's target, held by the container's translation, until the next layout pass places
    /// them at the camera. The fling's leading-column report is owed at the CPU spring's rest.
    func takeCameraFromServer() {
        guard panContainer.fling != nil else { return }
        let camera = flingCamera
        let layout = layoutOffset
        panContainer.stopFling()
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
        if userMotionActive, !isUserScrolling {
            userMotionActive = false
            if !hasMotion { context.userMotionEnded() }
        }
        refreshDividerHover()
        context.overlayNeedsSync()
        context.requestFrames()
    }

    /// Lands a fling at once (the workspace hides): the views are at its target already.
    func finishPanFling() {
        guard panContainer.fling != nil else { return }
        panContainer.setTranslation(0)
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
        guard let visibilitySpan, panContainer.fling == nil else { return false }
        return visibilitySpan.span.contains(stripShift - visibilitySpan.shift)
    }
}
