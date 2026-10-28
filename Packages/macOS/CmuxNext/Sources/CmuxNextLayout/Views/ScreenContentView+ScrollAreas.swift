import AppKit
import CmuxNextDesign

/// Horizontal scroll areas (plans/cmux-next/scroll-areas-DESIGN.md). Each area keeps its own
/// `ScrollAreaScroll`: the column scroll reducer fed the area's cells, so reveal, camera
/// anchor, snapping and focus-after-scroll are the column strip's rules (S5). Offsets are client
/// view state, never sent. Panes outside an area's window are clipped and take no clicks.
extension ScreenContentView {
    /// The presented offset of each scroll area.
    var areaOffsets: [SplitID: CGFloat] { areaScrolls.mapValues(\.state.spring.value) }

    func areaOffset(of pane: PaneID) -> CGFloat {
        baseGeometry.scrollAreaOfPane[pane].flatMap { areaScrolls[$0]?.state.spring.value } ?? 0
    }

    func areaOffset(of kind: DividerHandleView.Kind) -> CGFloat {
        guard case let .split(id) = kind else { return 0 }
        return baseGeometry.scrollAreaOfSplit[id].flatMap { areaScrolls[$0]?.state.spring.value } ?? 0
    }

    /// The offset `pane`'s host is laid out at in its area: the area's pan base while a pan shows on the
    /// area's container, else ``areaOffset(of:)``.
    func areaLayoutOffset(of pane: PaneID) -> CGFloat {
        baseGeometry.scrollAreaOfPane[pane].flatMap { areaScrolls[$0]?.layoutOffset } ?? 0
    }

    func areaLayoutOffset(of kind: DividerHandleView.Kind) -> CGFloat {
        guard case let .split(id) = kind else { return 0 }
        return baseGeometry.scrollAreaOfSplit[id].flatMap { areaScrolls[$0]?.layoutOffset } ?? 0
    }

    var areasMoving: Bool {
        areaScrolls.values.map(\.state).contains { !$0.isGestureActive && ($0.spring.value != $0.spring.target || $0.spring.velocity != 0) }
    }

    /// The window of the area holding `pane`, in local coordinates (the strip's shift and the
    /// row's offset applied); nil outside an area.
    func displayedAreaWindow(of pane: PaneID) -> CGRect? {
        guard let window = baseGeometry.scrollAreaWindow(of: pane) else { return nil }
        return window.offsetBy(dx: geometry.scrolls(pane: pane) ? stripShift : 0, dy: -rowOffset(of: pane))
    }

    /// The local window of area `id`.
    func displayedAreaWindow(_ id: SplitID) -> CGRect? {
        baseGeometry.scrollAreas[id]?.panes.first.flatMap(displayedAreaWindow(of:))
    }

    /// The local window of area `id` where the views are laid out: the strip camera at `strip` and the
    /// row's offset as laid out (``rowLayoutOffset(of:)``). Its container clips there.
    func laidOutAreaWindow(_ id: SplitID, strip: CGFloat) -> CGRect? {
        guard let pane = baseGeometry.scrollAreas[id]?.panes.first, let window = baseGeometry.scrollAreaWindow(of: pane) else { return nil }
        return window.offsetBy(dx: geometry.scrolls(pane: pane) ? strip : 0, dy: -rowLayoutOffset(of: pane))
    }

    /// Feeds every area its cells and the focus (called with each `syncScroll`, before the
    /// strip: the inner reveal first, K2). An area that stops overflowing drops its offset.
    /// Returns true if a spring needs frames.
    @discardableResult
    func syncAreas(focused: PaneID?, source: ColumnFocusSource, animated: Bool, reveals: Bool) -> Bool {
        var needsFrames = false
        for id in areaScrolls.keys where baseGeometry.scrollAreas[id] == nil { areaScrolls[id] = nil }
        for (id, area) in baseGeometry.scrollAreas {
            var scroll = areaScrolls[id] ?? ScrollAreaScroll()
            if areaScrolls[id] == nil { scroll.state.pendingRestore = pendingScroll.areas.removeValue(forKey: id) }
            let event = ColumnScrollEvent.sync(scroll.strip(area), focused: focused, source: source, animated: animated, reveals: reveals)
            if scrollerFlingYields(.area(id), to: { _ = $0.reduce(event) }) {
                takeScrollerFromServer(.area(id))
                scroll = areaScrolls[id] ?? scroll
            }
            let effects = scroll.state.reduce(event)
            areaScrolls[id] = scroll
            if effects.needsFrames { needsFrames = true }
        }
        refreshRowShift()
        return needsFrames
    }

    /// Steps the area springs; true while one moves.
    func stepAreas(_ dt: Double, policy: MotionPolicy) -> Bool {
        var moving = false
        let spring = policy.spring(.scroll)
        for id in Array(areaScrolls.keys) where areaScrolls[id]?.state.isGestureActive == false {
            if areaScrolls[id]?.state.spring.advance(dt, parameters: spring, epsilon: 0.25) == true { moving = true }
        }
        if !areaScrolls.isEmpty { refreshRowShift() }
        return moving
    }

    // MARK: Input (I1 to I5)

    /// The scroll area a horizontal scroll at `localPoint` moves: the innermost area under the
    /// pointer that can move in `direction` (+1 scrolls content toward its end, -1 toward its
    /// start), or nil, which leaves the gesture to the strip (I2).
    func scrollArea(at localPoint: NSPoint, direction: Int) -> SplitID? {
        guard context.style.scrollAreasEnabled else { return nil }
        for (id, area) in baseGeometry.scrollAreas {
            guard let window = displayedAreaWindow(id), window.contains(localPoint), let scroll = areaScrolls[id] else { continue }
            if geometry.scrolls(pane: area.panes.first ?? PaneID("")), !uncoveredRect.contains(localPoint) { continue }
            let offset = scroll.state.spring.value
            if direction > 0 ? offset < area.maxOffset - 0.5 : offset > 0.5 { return id }
        }
        return nil
    }

    func beginAreaScroll(_ id: SplitID) {
        // A touch takes the area from a fling on the render server, where it shows.
        takeScrollerFromServer(.area(id))
        areaScrolls[id]?.state.reduce(.gestureBegan)
    }

    /// A trackpad delta (points; positive moves content right, as AppKit reports it). On the area's
    /// motion container it moves one layer property and lays nothing out (``presentScrollerPan(_:)``).
    func areaScroll(_ id: SplitID, deltaX: CGFloat, timestamp: TimeInterval) {
        areaScrolls[id]?.state.reduce(.gestureChanged(deltaX: deltaX, time: timestamp))
        refreshRowShift()
        if !presentScrollerPan(.area(id)) { applyPresentation() }
    }

    /// Ends a trackpad gesture: projects the fling and springs to a snap point. After a pan on the area's
    /// container the fling runs on the render server (``startScrollerFling(_:)``), else on the CPU.
    @discardableResult
    func endAreaScroll(_ id: SplitID, timestamp: TimeInterval) -> Bool {
        guard var scroll = areaScrolls[id] else { return false }
        let effects = scroll.state.reduce(.gestureEnded(time: timestamp, animated: !context.reduceMotion))
        areaScrolls[id] = scroll
        guard effects.needsFrames, startScrollerFling(.area(id)) else { return applyArea(effects) }
        if let pane = effects.focus { context.model.focus(pane, source: .scroll) }
        return false
    }

    /// One mouse wheel notch (Shift-wheel) on an area.
    @discardableResult
    func discreteAreaScroll(_ id: SplitID, direction: Int) -> Bool {
        takeScrollerFromServer(.area(id))
        guard var scroll = areaScrolls[id] else { return false }
        let effects = scroll.state.reduce(.wheel(direction: direction, animated: !context.reduceMotion))
        areaScrolls[id] = scroll
        return applyArea(effects)
    }

    private func applyArea(_ effects: ColumnScrollEffects) -> Bool {
        refreshRowShift()
        applyPresentation()
        if let pane = effects.focus { context.model.focus(pane, source: .scroll) }
        return effects.needsFrames
    }
}
