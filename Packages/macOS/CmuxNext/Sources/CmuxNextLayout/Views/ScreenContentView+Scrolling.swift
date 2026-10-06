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
        let animate = animated && !context.reduceMotion && bounds.width > 0
        let rowsNeedFrames = syncRows(focused: focused, source: source, animated: animate, reveals: reveals)
        guard let strip else {
            scrollState = ColumnScrollState()
            applyPresentation()
            return rowsNeedFrames
        }
        scrollState.mode = mode
        let effects = scrollState.reduce(.sync(strip, focused: focused, source: source, animated: animate, reveals: reveals))
        if effects.snapped && showsScrollbarOnSnap { scrollbarFlash = true }
        return apply(effects) || rowsNeedFrames
    }

    /// Centers the column holding `pane` once. Returns true if the spring needs frames.
    @discardableResult
    func center(_ pane: PaneID, animated: Bool) -> Bool {
        scrollbarFlash = true
        return apply(scrollState.reduce(.center(pane, animated: animated && !context.reduceMotion)))
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
        apply(scrollState.reduce(.page(to: offset, animated: !context.reduceMotion)))
    }

    func beginUserScroll() {
        scrollState.reduce(.gestureBegan)
    }

    func userScroll(deltaX: CGFloat, timestamp: TimeInterval) {
        scrollState.reduce(.gestureChanged(deltaX: deltaX, time: timestamp))
        scrollbarFlash = true
        applyPresentation()
    }

    /// Ends a trackpad gesture: projects the fling and springs to a snap point.
    func endUserScroll(timestamp: TimeInterval) {
        scrollbarFlash = true
        apply(scrollState.reduce(.gestureEnded(time: timestamp, animated: !context.reduceMotion)))
    }

    /// One mouse wheel notch: move to the adjacent snap point.
    func discreteScroll(direction: Int) {
        scrollbarFlash = true
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
