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
    /// for a window resize, launch, or a view out of its window.
    @discardableResult
    func syncScroll(focused: PaneID?, source: ColumnFocusSource, mode: CenterFocusedColumn, animated: Bool, reveals: Bool = true,
                    showsScrollbarOnSnap: Bool = false) -> Bool {
        lastFocused = focused
        defer { leadIfPending() }
        let animate = animated && !context.reduceMotion && bounds.width > 0
        // Inner first (scroll-areas-DESIGN.md K2): areas, then rows, then the strip.
        let areasNeedFrames = syncAreas(focused: focused, source: source, animated: animate, reveals: reveals)
        let rowsNeedFrames = syncRows(focused: focused, source: source, animated: animate, reveals: reveals) || areasNeedFrames
        guard let strip else {
            scrollState = ColumnScrollState()
            settleCarried()
            applyPresentation()
            // Resetting the camera can start a carried pane off screen. Keep its spring
            // ticking while this workspace stays visible (Lucas 2026-10-19).
            return hasMotion || rowsNeedFrames
        }
        scrollState.mode = mode
        let effects = scrollState.reduce(.sync(strip, focused: focused, source: source, animated: animate, reveals: reveals,
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
        scrollRidesFrames = false
        return apply(scrollState.reduce(reveal ? .reveal(pane, animated: animated && !context.reduceMotion) : .center(pane, animated: animated && !context.reduceMotion)))
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
        scrollRidesFrames = false
        apply(scrollState.reduce(.page(to: offset, animated: !context.reduceMotion)))
    }

    func beginUserScroll() {
        // The user takes the camera over from a close in flight: its snap springs on the scroll spring.
        scrollRidesFrames = false
        scrollState.reduce(.gestureBegan)
    }

    func userScroll(deltaX: CGFloat, timestamp: TimeInterval) {
        scrollState.reduce(.gestureChanged(deltaX: deltaX, time: timestamp))
        scrollbarFlash = true
        presentPan()
    }

    /// Ends a trackpad gesture: projects the fling and springs to a snap point.
    func endUserScroll(timestamp: TimeInterval) {
        scrollbarFlash = true
        // The landing presents the strip (now, or on the fling's frames): nothing waits for a tick.
        panPresentationPending = false
        apply(scrollState.reduce(.gestureEnded(time: timestamp, animated: !context.reduceMotion)))
    }

    /// One mouse wheel notch: move to the adjacent snap point.
    func discreteScroll(direction: Int) {
        scrollbarFlash = true
        scrollRidesFrames = false
        apply(scrollState.reduce(.wheel(direction: direction, animated: !context.reduceMotion)))
    }

    @discardableResult
    private func apply(_ effects: ColumnScrollEffects) -> Bool {
        if effects.reportOnSettle { reportScrollOnSettle = true }
        if !effects.needsFrames { applyPresentation() }
        if let pane = effects.focus {
            lastFocused = pane
            context.model.focus(pane, source: .scroll)
        }
        if !effects.needsFrames && reportScrollOnSettle {
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
