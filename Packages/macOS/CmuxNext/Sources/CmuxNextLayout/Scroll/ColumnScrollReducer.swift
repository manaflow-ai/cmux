public import CoreGraphics
public import CmuxNextDesign
public import Foundation

/// The column scroll rules (plans/cmux-next/niri.md): minimal reveal of the
/// focused column, niri's `center-focused-column` modes, a camera anchored on
/// the focused column across layout and window changes, the restore of the
/// previous offset when a just-opened column closes, and trackpad and wheel
/// snapping that never fights the automatic reveal. Pure: no AppKit.
extension ColumnScrollState {
    @discardableResult
    public mutating func reduce(_ event: ColumnScrollEvent) -> ColumnScrollEffects {
        var effects = ColumnScrollEffects()
        switch event {
        case let .sync(strip, focused, source, animated, reveals):
            sync(strip, focused: focused, source: source, reveals: reveals)
            finish(animated: animated, into: &effects)
        case let .center(pane, animated):
            guard gesture == nil, let strip, let index = strip.index(ofPane: pane) else { return effects }
            spring.target = ColumnViewOffset.center(strip.columns[index].frame, current: spring.target, strip: strip)
            finish(animated: animated, into: &effects)
        case .gestureBegan:
            // The gesture takes over from the presented value: an automatic
            // scroll in flight stops where it is (niri `view_offset_gesture_begin`).
            gesture = Gesture(raw: spring.value)
            spring.velocity = 0
            spring.target = spring.value
        case let .gestureChanged(deltaX, time):
            guard var live = gesture, let strip else { return effects }
            live.raw -= deltaX
            live.samples.append(Sample(time: time, delta: -deltaX))
            live.samples.removeAll { time - $0.time > 0.1 }
            gesture = live
            spring.value = ColumnStripGeometry.rubberBand(live.raw, contentWidth: strip.contentWidth, viewportWidth: strip.viewportWidth)
            spring.target = spring.value
        case let .gestureEnded(time, animated):
            guard let live = gesture else { return effects }
            gesture = nil
            let recent = live.samples.filter { time - $0.time <= 0.1 }
            var velocity: CGFloat = 0
            if let first = recent.first, recent.count > 1 {
                velocity = recent.reduce(0) { $0 + $1.delta } / CGFloat(max(time - first.time, 1.0 / 120.0))
            }
            guard let strip else { return effects }
            let snaps = ColumnViewOffset.snaps(strip: strip, mode: mode)
            let target = ColumnStripGeometry.snapTarget(releaseOffset: spring.value, velocity: velocity, snaps: snaps.map(\.offset))
            let forward = target >= spring.value
            spring.target = target
            spring.velocity = velocity
            moveFocusAfterScroll(to: target, snaps: snaps, forward: forward, into: &effects)
            effects.reportOnSettle = true
            finish(animated: animated, into: &effects)
        case let .wheel(direction, animated):
            guard gesture == nil, let strip else { return effects }
            let snaps = ColumnViewOffset.snaps(strip: strip, mode: mode)
            spring.target = ColumnStripGeometry.adjacentSnap(from: spring.target, direction: direction, snaps: snaps.map(\.offset))
            moveFocusAfterScroll(to: spring.target, snaps: snaps, forward: direction > 0, into: &effects)
            effects.reportOnSettle = true
            finish(animated: animated, into: &effects)
        }
        return effects
    }

    private mutating func finish(animated: Bool, into effects: inout ColumnScrollEffects) {
        if let strip, gesture == nil { spring.target = strip.clamp(spring.target) }
        if !animated, gesture == nil { spring.snap() }
        effects.needsFrames = spring.value != spring.target || spring.velocity != 0
    }

    private mutating func sync(_ new: ColumnStrip, focused: PaneID?, source: ColumnFocusSource, reveals: Bool) {
        let old = strip
        let oldPane = focusedPane
        let oldColumn = focusedColumn
        strip = new
        focusedPane = focused
        let index = focused.flatMap(new.index(ofPane:))
        focusedColumn = index.map { new.columns[$0].id }
        if let focused, let focusedColumn { remembered[focusedColumn] = focused }
        let live = Set(new.columns.map(\.id))
        remembered = remembered.filter { live.contains($0.key) }

        guard let old else {
            // First strip: place the focused column, no animation.
            if let index {
                spring.target = ColumnViewOffset.target(column: index, pane: focused, current: spring.target, mode: mode, previous: nil, strip: new)
            }
            spring.snap()
            return
        }

        // 1. Camera: keep the previously focused column where it is on screen
        //    across insertions, removals, width and window changes (niri keeps
        //    the view offset relative to the active column). A reorder (move
        //    column) keeps the camera itself (niri `move_column_to`).
        var delta: CGFloat = 0
        if new.keepsOrder(of: old) || old.viewportWidth != new.viewportWidth,
           let anchor = oldColumn,
           let before = old.index(of: anchor), let after = new.index(of: anchor) {
            delta = new.columns[after].frame.minX - old.columns[before].frame.minX
        }
        spring.value += delta
        spring.target += delta
        gesture?.raw += delta

        // 2. Restore after closing a column that was just opened to the right.
        let removed = Set(old.columns.map(\.id)).subtracting(live)
        let added = live.subtracting(old.columns.map(\.id))
        var restored = false
        if let point = restore {
            if removed.contains(point.opened), focusedColumn == point.column, let at = new.index(of: point.column) {
                spring.target = new.columns[at].frame.minX + point.relativeOffset
                restored = true
                restore = nil
            } else if removed.contains(point.column) || (focusedColumn != point.opened && focusedColumn != point.column) {
                restore = nil
            }
        }
        if added.count == 1, let opened = added.first, focusedColumn == opened, let previous = oldColumn,
           let previousIndex = new.index(of: previous), new.index(of: opened) == previousIndex + 1
        {
            restore = RestorePoint(column: previous, opened: opened,
                                   relativeOffset: spring.target - new.columns[previousIndex].frame.minX)
        }

        // 3. Reveal. A live gesture owns the target; its end keeps the
        //    focused column visible.
        guard gesture == nil else { return }
        guard reveals else {
            revealDeferred = true
            return
        }
        let deferred = revealDeferred
        revealDeferred = false
        guard let index else { return }
        let columnChanged = focusedColumn != oldColumn
        guard focused != oldPane || old != new || restored || deferred else { return }
        var effectiveMode = source == .pointer || source == .scroll ? .never : mode
        if !columnChanged && focused == oldPane && effectiveMode == .always,
           let before = oldColumn.flatMap(old.index(of:)),
           abs(old.columns[before].frame.midX - old.viewportWidth / 2 - (spring.target - delta)) > 1
        {
            // A layout-only change keeps a column that was not centered
            // (clicked into view) where fitting puts it.
            effectiveMode = .never
        }
        let previous = columnChanged ? oldColumn.flatMap(new.index(of:)) : nil
        spring.target = ColumnViewOffset.target(column: index, pane: focused, current: spring.target,
                                                mode: effectiveMode, previous: previous, strip: new)
    }

    private mutating func moveFocusAfterScroll(to target: CGFloat, snaps: [ColumnViewOffset.Snap], forward: Bool, into effects: inout ColumnScrollEffects) {
        guard let strip else { return }
        let snapColumn = snaps.min { abs($0.offset - target) < abs($1.offset - target) }?.column ?? 0
        let focusedIndex = focusedColumn.flatMap(strip.index(of:))
        guard let next = ColumnViewOffset.focusAfterScroll(focused: focusedIndex, snapColumn: snapColumn, target: target,
                                                           forward: forward, strip: strip) else { return }
        let column = strip.columns[next]
        guard let pane = remembered[column.id] ?? column.panes.first else { return }
        // Recorded now, so the model's echo of this focus is not a change.
        focusedPane = pane
        focusedColumn = column.id
        restore = nil
        effects.focus = pane
    }
}
