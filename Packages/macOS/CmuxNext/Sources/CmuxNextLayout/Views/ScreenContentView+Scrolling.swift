import AppKit
import CmuxNextDesign

/// Column strip scrolling: focus reveal, trackpad gestures with rubber
/// banding and fling projection, and discrete mouse-wheel snaps.
extension ScreenContentView {
    /// Scrolls so `pane`'s column is visible per `mode`. Returns true if frames are needed.
    @discardableResult
    func reveal(_ pane: PaneID, mode: ColumnRevealMode, animated: Bool) -> Bool {
        guard geometry.isColumns, let column = layout.column(containing: pane), let frame = geometry.columns[column.id] else { return false }
        let target = ColumnStripGeometry.revealOffset(
            for: frame,
            current: scroll.target,
            viewportWidth: bounds.width,
            contentWidth: geometry.contentWidth,
            gap: context.style.stripGap,
            mode: mode
        )
        guard target != scroll.target else { return false }
        scroll.target = target
        reportScrollOnSettle = true
        if !animated || context.reduceMotion {
            scroll.snap()
            applyPresentation()
            reportScrollOnSettle = false
            reportLeadingColumn()
            return false
        }
        return true
    }

    var acceptsHorizontalScroll: Bool { geometry.isColumns && geometry.maxOffset > 0.5 }

    func beginUserScroll() {
        isUserScrolling = true
        scroll.velocity = 0
        rawScroll = scroll.value
        scrollSamples.removeAll()
    }

    func userScroll(deltaX: CGFloat, timestamp: TimeInterval) {
        rawScroll -= deltaX
        scroll.value = ColumnStripGeometry.rubberBand(rawScroll, contentWidth: geometry.contentWidth, viewportWidth: bounds.width)
        scroll.target = scroll.value
        scrollSamples.append((timestamp, -deltaX))
        scrollSamples.removeAll { timestamp - $0.time > 0.1 }
        applyPresentation()
    }

    /// Ends a trackpad gesture: projects the fling and springs to a column edge.
    func endUserScroll(timestamp: TimeInterval) {
        isUserScrolling = false
        let recent = scrollSamples.filter { timestamp - $0.time <= 0.1 }
        var velocity: CGFloat = 0
        if let first = recent.first, recent.count > 1 {
            let dt = max(timestamp - first.time, 1.0 / 120.0)
            velocity = recent.reduce(0) { $0 + $1.delta } / CGFloat(dt)
        }
        scrollSamples.removeAll()
        let target = ColumnStripGeometry.snapTarget(releaseOffset: scroll.value, velocity: velocity, snaps: geometry.snapOffsets)
        scroll.target = target
        scroll.velocity = velocity
        reportScrollOnSettle = true
        if context.reduceMotion {
            scroll.snap()
            applyPresentation()
        }
    }

    /// One mouse wheel notch: move to the adjacent snap point.
    func discreteScroll(direction: Int) {
        scroll.target = ColumnStripGeometry.adjacentSnap(from: scroll.target, direction: direction, snaps: geometry.snapOffsets)
        reportScrollOnSettle = true
        if context.reduceMotion {
            scroll.snap()
            applyPresentation()
        }
    }

    func reportLeadingColumn() {
        guard geometry.isColumns,
              let index = ColumnStripGeometry.leadingColumnIndex(frames: geometry.orderedColumnFrames, offset: scroll.value, gap: context.style.stripGap)
        else { return }
        context.model.reportScroll(screen: screenID, leadingColumn: geometry.columnOrder[index])
    }
}
