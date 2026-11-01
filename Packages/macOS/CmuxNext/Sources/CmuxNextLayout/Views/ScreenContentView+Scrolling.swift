import AppKit
import CmuxNextDesign

/// Column strip scrolling. Every rule lives in `ColumnScrollState.reduce`
/// (plans/cmux-next/column-scroll.md); this extension feeds it model snapshots,
/// trackpad gestures and wheel notches, and applies its effects.
extension ScreenContentView {
    /// The strip the reducer sees now; nil on a split screen.
    private var strip: ColumnStrip? {
        ColumnStrip(layout: layout, geometry: geometry, gap: context.style.stripGap)
    }

    /// Feeds the current layout, geometry and focus to the reducer. Returns
    /// true if the spring needs frames. A reveal that snaps (animation off,
    /// Reduce Motion) shows the `auto` scrollbar like the spring frames it
    /// replaces, only when `showsScrollbarOnSnap`: the caller passes false
    /// for a window resize, launch, or a view out of its window. Part of a
    /// change turn: a close's first frame waits for its end (`endMotionTurn`).
    @discardableResult
    func syncScroll(focused: PaneID?, source: ColumnFocusSource, mode: CenterFocusedColumn, animated: Bool, reveals: Bool = true,
                    showsScrollbarOnSnap: Bool = false) -> Bool {
        lastFocused = focused
        let animate = animated && !context.reduceMotion && bounds.width > 0
        // Inner first (scroll-areas-DESIGN.md K2): areas, then rows, then the strip.
        let areasNeedFrames = syncAreas(focused: focused, source: source, animated: animate, reveals: reveals)
        let rowsNeedFrames = syncRows(focused: focused, source: source, animated: animate, reveals: reveals) || areasNeedFrames
        dropPendingScrollIfSized()
        guard let strip else {
            scrollState = ColumnScrollState()
            settleCarried()
            applyPresentation()
            // Resetting the camera can start a carried pane off screen. Keep its spring
            // ticking while this workspace stays visible (Lucas 2026-10-19).
            return hasMotion || rowsNeedFrames
        }
        scrollState.mode = mode
        let effects = reduceCamera(.sync(strip, focused: focused, source: source, animated: animate, reveals: reveals,
                                         anchor: ScreenDividers(screen: self).dragAnchorColumn))
        settleCarried()
        if effects.snapped && showsScrollbarOnSnap { scrollbarFlash = true }
        let needsFrames = apply(effects)
        return needsFrames || hasMotion || rowsNeedFrames
    }

    /// Centers the column holding `pane` once, or with `reveal` scrolls it the least into view (cx-27j7). Returns true if the spring needs frames.
    @discardableResult
    func center(_ pane: PaneID, animated: Bool, reveal: Bool = false) -> Bool {
        scrollbarFlash = true
        cpuTakesCamera()
        return apply(reduceCamera(reveal ? .reveal(pane, animated: animated && !context.reduceMotion) : .center(pane, animated: animated && !context.reduceMotion)))
    }

    var acceptsHorizontalScroll: Bool { geometry.isColumns && geometry.maxOffset > 0.5 }

    /// A horizontal scroll at `localPoint` scrolls the strip only over its
    /// uncovered range; over a docked column it stays with the pane.
    func acceptsHorizontalScroll(at localPoint: NSPoint) -> Bool {
        acceptsHorizontalScroll && uncoveredRect.contains(localPoint)
    }

    /// A scrollbar track click: rest on `offset` (ColumnScrollEvent.page).
    func page(to offset: CGFloat) {
        scrollbarFlash = true
        cpuTakesCamera()
        motionTurn { apply(reduceCamera(.page(to: offset, animated: !context.reduceMotion))) }
    }

    /// Begins a strip pan. `trackpad`: a trackpad gesture (``LayoutRootView`` scroll routing), whose
    /// pan the feature `stripPanResampling` resamples; a scrollbar thumb drag follows the pointer, as
    /// Chromium resamples only touchpad and touchscreen scroll updates.
    func beginUserScroll(trackpad: Bool = false) {
        // The user takes the camera over from a close in flight: its snap springs on the scroll spring.
        cpuTakesCamera()
        // And from a fling on the render server, where it shows.
        takeCameraFromServer()
        // Feature `stripPanResampling`: the pan shows at each frame's time (`presentFramePan`). Not under
        // Reduce Motion, as resampled drags.
        scrollState.resamplesPan = trackpad && context.resamplesStripPan && !context.reduceMotion
        scrollState.reduce(.gestureBegan)
    }

    /// A pan point that a later one of the same frame delivery supersedes (a coalesced thumb drag): it
    /// moves the gesture and counts toward the release velocity, and the next ``userScroll`` shows it.
    func userScrollSample(deltaX: CGFloat, timestamp: TimeInterval) {
        scrollState.reduce(.gestureChanged(deltaX: deltaX, time: timestamp))
    }

    func userScroll(deltaX: CGFloat, timestamp: TimeInterval) {
        scrollState.reduce(.gestureChanged(deltaX: deltaX, time: timestamp))
        scrollbarFlash = true
        if scrollState.resamplesPan {
            // A resampled pan on the strip container: after its first event, the next frame shows it.
            // Reduce Motion turned on mid-pan steps no frames: the event shows now, unresampled.
            if panBase != nil, pansOnContainer, !context.reduceMotion {
                context.requestFrames()
                return
            }
            scrollState.panShownUnresampled()
        }
        // On the strip container: one layer property, no frame. Else the panes move (`presentPan`).
        if !presentPanOnContainer() { presentPan() }
    }

    /// A display frame began during a resampled pan (``ColumnScrollState/resamplesPan``): the pan
    /// events since the last frame show now, at the offset resampled at `frameTime` (Chrome's scroll
    /// resampling at the begin-frame, `ui/base/prediction/linear_resampling.cc`). Nil `frameTime` (a
    /// frame stepped by hand, or Reduce Motion's settling frame) shows the real offset.
    func presentFramePan(at frameTime: TimeInterval?) { // perf-hot: 0.3ms motion-frame
        guard scrollState.resamplesPan, panBase != nil, scrollState.framePan(at: frameTime) != nil else { return }
        if !presentPanOnContainer() { presentPan() }
    }

    /// Ends a trackpad gesture: projects the fling and springs to a snap point. After a pan on the
    /// strip container the fling runs on the render server (`startPanFling`), else on the CPU.
    func endUserScroll(timestamp: TimeInterval) {
        scrollbarFlash = true
        // The landing presents the strip (now, or on the fling's frames): nothing waits for a tick.
        panPresentationPending = false
        let onContainer = panBase != nil && pansOnContainer
        motionTurn {
            let effects = scrollState.reduce(.gestureEnded(time: timestamp, animated: !context.reduceMotion))
            guard onContainer, effects.needsFrames, startPanFling() else { return apply(effects) }
            // The landing reports the leading column (`panFlingLanded`); the focus moves now, as on the CPU.
            if let pane = effects.focus {
                lastFocused = pane
                context.model.focus(pane, source: .scroll)
            }
            return false
        }
    }

    /// One mouse wheel notch: move to the adjacent snap point.
    func discreteScroll(direction: Int) {
        scrollbarFlash = true
        cpuTakesCamera()
        motionTurn { apply(reduceCamera(.wheel(direction: direction, animated: !context.reduceMotion))) }
    }

    /// `event` on the reducer. During a fling on the render server, an event that leaves the camera
    /// where it rests (a focus sync that reveals the column it lands on) lets the fling go on; one
    /// that moves it takes the camera first (``takeCameraFromServer()``), so it moves from where the
    /// strip shows.
    private func reduceCamera(_ event: ColumnScrollEvent) -> ColumnScrollEffects {
        guard stripContainer.fling != nil else { return scrollState.reduce(event) }
        var probe = scrollState
        let effects = probe.reduce(event)
        if probe.spring == scrollState.spring {
            scrollState = probe
            return effects
        }
        takeCameraFromServer()
        return scrollState.reduce(event)
    }

    @discardableResult
    private func apply(_ effects: ColumnScrollEffects) -> Bool {
        if effects.reportOnSettle { reportScrollOnSettle = true }
        if !effects.needsFrames { applyPresentation() }
        if let pane = effects.focus {
            lastFocused = pane
            context.model.focus(pane, source: .scroll)
        }
        // A close whose frame spring carries the camera's shift (``scrollRidesFrames``) still moves what
        // the camera showed: the report waits for it, at the render-server landing (``RenderClose``) or
        // the CPU frame that rests the camera (`step`), not in the close's turn.
        if !effects.needsFrames && reportScrollOnSettle && !(scrollRidesFrames && hasMotion) {
            reportScrollOnSettle = false
            reportLeadingColumn()
        }
        return effects.needsFrames
    }

    func reportLeadingColumn() {
        guard geometry.isColumns,
              let index = ColumnStripGeometry.leadingColumnIndex(frames: geometry.orderedColumnFrames, offset: scroll.value, gap: context.style.stripGap)
        else { return }
        context.model.reportScroll(screen: screenID, leadingColumn: geometry.columnOrder[index])
    }
}
