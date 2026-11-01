public import CoreGraphics
public import CmuxNextDesign
public import Foundation
import CmuxNextInputCore

/// The column scroll rules (plans/cmux-next/column-scroll.md): minimal reveal of the
/// focused column, the column centering modes, a camera anchored on
/// the focused column across layout and window changes, the restore of the
/// previous offset when a just-opened column closes, and trackpad and wheel
/// snapping that never fights the automatic reveal. Pure: no AppKit.
nonisolated extension ColumnScrollState {
    @discardableResult
    public mutating func reduce(_ event: ColumnScrollEvent) -> ColumnScrollEffects {
        var effects = ColumnScrollEffects()
        switch event {
        case let .sync(strip, focused, source, animated, reveals, anchor):
            if let saved = pendingRestore, strip.viewportWidth > 0, gesture == nil {
                pendingRestore = nil
                restoreCamera(at: saved, strip: strip, focused: focused)
                return effects
            }
            let before = spring.target
            let shift = sync(strip, focused: focused, source: source, reveals: reveals, anchor: anchor)
            // A sync that leaves the target where the camera shift put it never snaps: a fling or
            // wheel spring in flight keeps moving while pane layout motion is off (motion.md rule 9).
            let moved = abs(strip.clamp(spring.target) - (before + shift)) > 0.25
            finish(animated: animated || !moved, into: &effects)
        case let .center(pane, animated):
            guard gesture == nil, let strip, let index = strip.index(ofPane: pane) else { return effects }
            spring.target = ColumnViewOffset.center(strip.columns[index].frame, current: spring.target, strip: strip)
            finish(animated: animated, into: &effects)
        case let .reveal(pane, animated):
            guard gesture == nil, let strip, let index = strip.index(ofPane: pane) else { return effects }
            spring.target = ColumnViewOffset.target(column: index, pane: pane, current: spring.target, mode: .never,
                                                    previous: nil, strip: strip)
            finish(animated: animated, into: &effects)
        case .gestureBegan:
            // The gesture takes over from the presented value: an automatic
            // scroll in flight stops where it is.
            gesture = Gesture(raw: spring.value, resampler: resamplesPan ? InputResampler() : nil)
            spring.velocity = 0
            spring.target = spring.value
        case let .gestureChanged(deltaX, time):
            guard var live = gesture, let strip else { return effects }
            live.raw -= deltaX
            live.samples.append(Sample(time: time, delta: -deltaX))
            live.samples.removeAll { time - $0.time > 0.1 }
            live.resampler?.update(PointerSample(location: InputPoint(x: Double(live.raw), y: 0), timestamp: time))
            live.framePending = true
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
        case let .page(offset, animated):
            guard gesture == nil, let strip else { return effects }
            let target = strip.clamp(offset)
            let forward = target >= spring.target
            spring.target = target
            moveFocusAfterScroll(to: target, snaps: ColumnViewOffset.snaps(strip: strip, mode: mode), forward: forward, into: &effects)
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

    /// The strip pan a display frame shows, or nil when no pan event came since the
    /// last frame: the gesture's raw offset at `frameTime` through Chromium's resampling
    /// (`InputResampler`, `ui/base/prediction/linear_resampling.cc`; Chrome resamples the frame's
    /// scroll updates at `BeginFrameArgs::frame_time` in `InputHandlerProxy::DeliverInputForBeginFrame`),
    /// then rubber-banded. It lies between the two newest real samples or past the newest within the
    /// resampler's cap, never behind the older one nor back from what the last frame showed against the
    /// newest event's direction; ``presentedPan`` keeps it for every presentation until the next frame. Visual only: ``spring`` keeps the real offset, so the
    /// snap and the fling read real samples. Not resampled (``resamplesPan`` off, too few samples, or
    /// a nil `frameTime`: a frame with no display time) it is the real offset.
    public mutating func framePan(at frameTime: TimeInterval?) -> CGFloat? {
        guard var live = gesture, live.framePending, strip != nil else { return nil }
        live.framePending = false
        var raw = live.raw
        if let frameTime, let sample = live.resampler?.resample(frameTime: frameTime) {
            let delta = live.samples.last?.delta ?? 0
            let previous = live.raw - delta
            raw = CGFloat(sample.location.x)
            if (raw - previous) * delta < 0 { raw = previous }
            // Never back against the newest event from what the last frame showed: a frame that extrapolated
            // past a sample, then a slower event, would else step the strip backward
            // (`ScrollPredictor::ResampleEvent`, third_party/blink/renderer/platform/widget/input/scroll_predictor.cc).
            if let shown = live.shownRaw, (raw - shown) * delta < 0 { raw = shown }
        }
        live.shownRaw = raw
        gesture = live
        return presentedPan
    }

    /// The strip pan the last frame showed (rubber-banded), or nil when no frame of the gesture showed
    /// one: during a resampled pan the strip shows this, not the camera (``spring`` keeps the real offset).
    public var presentedPan: CGFloat? {
        guard let raw = gesture?.shownRaw, let strip else { return nil }
        return ColumnStripGeometry.rubberBand(raw, contentWidth: strip.contentWidth, viewportWidth: strip.viewportWidth)
    }

    /// The gesture's newest event showed in its own turn, unresampled (its first event, or one under
    /// Reduce Motion): the frames after it go on from there.
    public mutating func panShownUnresampled() {
        guard var live = gesture else { return }
        live.framePending = false
        live.shownRaw = live.raw
        gesture = live
    }

    private mutating func finish(animated: Bool, into effects: inout ColumnScrollEffects) {
        if let strip, gesture == nil { spring.target = strip.clamp(spring.target) }
        if !animated, gesture == nil {
            // The spring's rest epsilon: less than this would not have stepped.
            effects.snapped = abs(spring.target - spring.value) > 0.25
            spring.snap()
        }
        effects.needsFrames = spring.value != spring.target || spring.velocity != 0
    }

    /// Returns the camera shift it applied to the value and the target (step 1).
    @discardableResult
    private mutating func sync(_ new: ColumnStrip, focused: PaneID?, source: ColumnFocusSource, reveals: Bool, anchor anchorOverride: ColumnID?) -> CGFloat {
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
            return 0
        }

        // 1. Camera: keep the previously focused column (or the column under
        //    a resize drag) where it is on screen across insertions, removals,
        //    width and window changes. A reorder (move column) keeps the camera
        //    itself.
        var delta: CGFloat = 0
        if new.keepsOrder(of: old) || old.viewportWidth != new.viewportWidth,
           let anchor = anchorOverride ?? oldColumn,
           let before = old.index(of: anchor), let after = new.index(of: anchor) {
            delta = new.columns[after].frame.minX - old.columns[before].frame.minX
        }
        spring.value += delta
        spring.target += delta
        gesture?.raw += delta
        gesture?.shownRaw? += delta
        // The resampler's samples are in the old camera: the next two events start it again.
        if delta != 0 { gesture?.resampler?.reset() }

        // 2. Restore after closing a column that was just opened to the right.
        let removed = Set(old.columns.map(\.id)).subtracting(live)
        let added = live.subtracting(old.columns.map(\.id))
        var restored = false
        if let point = restore {
            // Only when the opened column was focused and its close moved
            // focus back: an unfocused close (the user went back first, or
            // the CLI closed it) must not scroll the focused column away
            // (close-focus.md, found by ColumnScrollCloseModelCheckTests S3).
            if removed.contains(point.opened), oldColumn == point.opened, focusedColumn == point.column,
               let at = new.index(of: point.column) {
                spring.target = new.columns[at].frame.minX + point.relativeOffset
                restored = true
                restore = nil
            } else if removed.contains(point.column) || removed.contains(point.opened)
                        || (focusedColumn != point.opened && focusedColumn != point.column) {
                restore = nil
            }
        }
        if added.count == 1, let opened = added.first, focusedColumn == opened, let previous = oldColumn,
           let previousIndex = new.index(of: previous), new.index(of: opened) == previousIndex + 1
        {
            restore = RestorePoint(column: previous, opened: opened,
                                   relativeOffset: spring.target - new.columns[previousIndex].frame.minX)
        }

        // A removed column cannot leave the camera past the new strip. The view carries the
        // panes horizontally from where they showed; row cameras keep their vertical spring.
        // Only a velocity out of the strip from where the camera now rests stops: one back into it
        // (a center or fling that was already coming back) goes on, so the close takes the camera at
        // the speed it shows. A strip that now fits has no inside to go back to: it stops at 0.
        if new.axis == .horizontal, !removed.isEmpty {
            let clamped = new.clamp(spring.value)
            if clamped != spring.value,
               (clamped >= new.maxOffset && spring.velocity > 0) || (clamped <= 0 && spring.velocity < 0) {
                spring.velocity = 0
            }
            spring.value = clamped
            spring.target = new.clamp(spring.target)
            if var live = gesture {
                let raw = new.clamp(live.raw)
                if raw != live.raw { live.resampler?.reset() }
                live.raw = raw
                live.shownRaw = live.shownRaw.map(new.clamp)
                gesture = live
            }
        }

        // 3. Reveal. A live gesture owns the target; its end keeps the
        //    focused column visible.
        guard gesture == nil else { return delta }
        guard reveals else {
            revealDeferred = true
            return delta
        }
        let deferred = revealDeferred
        revealDeferred = false
        guard let index else { return delta }
        let columnChanged = focusedColumn != oldColumn
        guard focused != oldPane || old != new || restored || deferred else { return delta }
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
        return delta
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
