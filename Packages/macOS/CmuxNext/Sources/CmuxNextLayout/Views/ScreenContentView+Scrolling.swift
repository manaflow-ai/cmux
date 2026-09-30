import AppKit
import CmuxNextDesign

/// Column strip scrolling. Every rule lives in `ColumnScrollState.reduce`
/// (plans/cmux-next/niri.md); this extension feeds it model snapshots,
/// trackpad gestures and wheel notches, and applies its effects.
extension ScreenContentView {
    /// The strip the reducer sees now; nil on a split screen.
    private var strip: ColumnStrip? {
        ColumnStrip(layout: layout, geometry: geometry, gap: context.style.stripGap)
    }

    /// Feeds the current layout, geometry and focus to the reducer. Returns
    /// true if the spring needs frames.
    @discardableResult
    func syncScroll(focused: PaneID?, source: ColumnFocusSource, mode: CenterFocusedColumn, animated: Bool, reveals: Bool = true) -> Bool {
        lastFocused = focused
        guard let strip else {
            scrollState = ColumnScrollState()
            applyPresentation()
            return false
        }
        scrollState.mode = mode
        let animate = animated && !context.reduceMotion && bounds.width > 0
        return apply(scrollState.reduce(.sync(strip, focused: focused, source: source, animated: animate, reveals: reveals)))
    }

    /// niri `center-column`. Returns true if the spring needs frames.
    @discardableResult
    func center(_ pane: PaneID, animated: Bool) -> Bool {
        apply(scrollState.reduce(.center(pane, animated: animated && !context.reduceMotion)))
    }

    var acceptsHorizontalScroll: Bool { geometry.isColumns && geometry.maxOffset > 0.5 }

    func beginUserScroll() {
        scrollState.reduce(.gestureBegan)
    }

    func userScroll(deltaX: CGFloat, timestamp: TimeInterval) {
        scrollState.reduce(.gestureChanged(deltaX: deltaX, time: timestamp))
        applyPresentation()
    }

    /// Ends a trackpad gesture: projects the fling and springs to a snap point.
    func endUserScroll(timestamp: TimeInterval) {
        apply(scrollState.reduce(.gestureEnded(time: timestamp, animated: !context.reduceMotion)))
    }

    /// One mouse wheel notch: move to the adjacent snap point.
    func discreteScroll(direction: Int) {
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
