import AppKit
import CmuxNextDesign

/// Vertical row scrolling (plans/cmux-next/rows.md, Viewport). Each column
/// whose rows overflow keeps its own `RowScroll`: the column scroll reducer
/// fed the column's rows as a strip on the vertical axis, so reveal,
/// camera anchor, snapping and focus-after-scroll are the column scroll
/// rules transposed (V1, V2). Offsets are client view state, never sent.
extension ScreenContentView {
    /// The presented vertical offset of each scrolling row column.
    var rowOffsets: [ColumnID: CGFloat] { rowScrolls.mapValues(\.state.spring.value) }

    func rowOffset(of pane: PaneID) -> CGFloat {
        baseGeometry.rowColumnOfPane[pane].flatMap { rowScrolls[$0]?.state.spring.value } ?? 0
    }

    func rowOffset(of kind: DividerHandleView.Kind) -> CGFloat {
        rowColumn(of: kind).flatMap { rowScrolls[$0]?.state.spring.value } ?? 0
    }

    /// The vertical offset `pane`'s host is laid out at: its row's pan base while a pan shows on the
    /// row's container, else ``rowOffset(of:)``.
    func rowLayoutOffset(of pane: PaneID) -> CGFloat {
        baseGeometry.rowColumnOfPane[pane].flatMap { rowScrolls[$0]?.layoutOffset } ?? 0
    }

    func rowLayoutOffset(of kind: DividerHandleView.Kind) -> CGFloat {
        rowColumn(of: kind).flatMap { rowScrolls[$0]?.layoutOffset } ?? 0
    }

    /// The row column whose vertical offset moves a divider handle, if any.
    func rowColumn(of kind: DividerHandleView.Kind) -> ColumnID? {
        switch kind {
        case let .split(id): baseGeometry.rowColumnOfSplit[id]
        case let .rowEdge(id, _): id
        case .columnEdge: nil
        }
    }

    var rowsMoving: Bool {
        rowScrolls.values.map(\.state).contains { !$0.isGestureActive && ($0.spring.value != $0.spring.target || $0.spring.velocity != 0) }
    }

    /// Feeds every row column the current rows and focus (called with each
    /// `syncScroll`). A column that stops overflowing drops its offset.
    /// Returns true if a spring needs frames.
    @discardableResult
    func syncRows(focused: PaneID?, source: ColumnFocusSource, animated: Bool, reveals: Bool) -> Bool {
        var needsFrames = false
        let scrolling = baseGeometry.rowStacks.filter { $0.value.scrolls }
        for id in rowScrolls.keys where scrolling[id] == nil {
            // A close that leaves the rest fitting the column: its frames glide from where they show.
            if animated { carryRowOffset(of: id) }
            rowScrolls[id] = nil
        }
        for (id, stack) in scrolling {
            guard let column = layout.columns.first(where: { $0.id == id }) else { continue }
            var scroll = rowScrolls[id] ?? RowScroll()
            if rowScrolls[id] == nil { scroll.state.pendingRestore = pendingScroll.rows.removeValue(forKey: id) }
            let strip = scroll.strip(rows: stack, column: column, panes: baseGeometry.panes)
            let event = ColumnScrollEvent.sync(strip, focused: focused, source: source, animated: animated, reveals: reveals)
            if scrollerFlingYields(.row(id), to: { _ = $0.reduce(event) }) {
                rowScrolls[id] = scroll
                takeScrollerFromServer(.row(id))
                scroll = rowScrolls[id] ?? scroll
            }
            let effects = scroll.state.reduce(event)
            rowScrolls[id] = scroll
            if effects.needsFrames { needsFrames = true }
        }
        refreshRowShift()
        return needsFrames
    }

    /// A row column that stops scrolling drops its offset: its pane and divider springs start where
    /// they show at that offset, so the change glides instead of jumping by it.
    private func carryRowOffset(of id: ColumnID) {
        guard let offset = rowScrolls[id]?.state.spring.value, abs(offset) > 0.25,
              let column = layout.columns.first(where: { $0.id == id }) else { return }
        let splits = Set(column.trees.flatMap(\.splits))
        for pane in column.trees.flatMap(\.panes) { paneFrames[pane]?.y.value -= offset }
        for kind in Array(dividerFrames.keys) {
            let inColumn: Bool = switch kind {
            case let .split(split): splits.contains(split)
            case let .rowEdge(edge, _): edge == id
            case .columnEdge: false
            }
            if inColumn { dividerFrames[kind]?.y.value -= offset }
        }
    }

    /// Steps the row springs on `spring` (the scroll spring, or a close's while the close moves);
    /// true while one moves.
    func stepRows(_ dt: Double, spring: SpringParameters) -> Bool {
        var moving = false
        for id in Array(rowScrolls.keys) where rowScrolls[id]?.state.isGestureActive == false {
            if rowScrolls[id]?.state.spring.advance(dt, parameters: spring, epsilon: 0.25) == true { moving = true }
        }
        if !rowScrolls.isEmpty { refreshRowShift() }
        return moving
    }

    /// Recomputes what hit testing reads from the presented row and scroll area offsets.
    func refreshRowShift() {
        geometry = baseGeometry.shiftingAreas(areaOffsets).shiftingRows(rowOffsets)
    }

    // MARK: Input (V5)

    /// The row column a vertical scroll at `localPoint` scrolls: one whose
    /// rows overflow, with the pointer over its gaps between rows, or
    /// anywhere in it while the row scroll modifier (Command) is held.
    /// Nil while rows are off (O2) or for a vertical scroll over a pane,
    /// which stays the terminal's.
    func rowScrollColumn(at localPoint: NSPoint, modifierHeld: Bool) -> ColumnID? {
        guard context.style.rowsEnabled else { return nil }
        for (id, stack) in baseGeometry.rowStacks where stack.scrolls && rowScrolls[id] != nil {
            let fixed = geometry.dock.contains { $0.column == id }
            let window = stack.frame.offsetBy(dx: fixed ? 0 : stripShift, dy: 0)
            guard window.contains(localPoint) else { continue }
            if fixed == false, !uncoveredRect.contains(localPoint) { continue }
            if modifierHeld { return id }
            let overPane = baseGeometry.rowColumnOfPane.contains { pane, column in
                column == id && (baseGeometry.panes[pane].map { displayedRect($0, pane: pane).contains(localPoint) } ?? false)
            }
            return overPane ? nil : id
        }
        return nil
    }

    func beginRowScroll(_ column: ColumnID) {
        cpuTakesCamera()
        // A touch takes the rows from a fling on the render server, where they show.
        takeScrollerFromServer(.row(column))
        rowScrolls[column]?.state.reduce(.gestureBegan)
    }

    /// A trackpad delta (points; positive moves content down, as AppKit
    /// reports it). On the row's motion container it moves one layer property and lays nothing out
    /// (``presentScrollerPan(_:)``); the gesture's end lays the rows out once where they show.
    func rowScroll(_ column: ColumnID, deltaY: CGFloat, timestamp: TimeInterval) {
        rowScrolls[column]?.state.reduce(.gestureChanged(deltaX: deltaY, time: timestamp))
        refreshRowShift()
        if !presentScrollerPan(.row(column)) { applyPresentation() }
    }

    /// Ends a trackpad gesture: projects the fling and springs to a snap point. After a pan on the row's
    /// container the fling runs on the render server (``startScrollerFling(_:)``), else on the CPU.
    @discardableResult
    func endRowScroll(_ column: ColumnID, timestamp: TimeInterval) -> Bool {
        guard var scroll = rowScrolls[column] else { return false }
        let effects = scroll.state.reduce(.gestureEnded(time: timestamp, animated: !context.reduceMotion))
        rowScrolls[column] = scroll
        guard effects.needsFrames, startScrollerFling(.row(column)) else { return applyRow(effects) }
        if let pane = effects.focus { context.model.focus(pane, source: .scroll) }
        return false
    }

    /// One mouse wheel notch on the vertical axis.
    @discardableResult
    func discreteRowScroll(_ column: ColumnID, direction: Int) -> Bool {
        cpuTakesCamera()
        takeScrollerFromServer(.row(column))
        guard var scroll = rowScrolls[column] else { return false }
        let effects = scroll.state.reduce(.wheel(direction: direction, animated: !context.reduceMotion))
        rowScrolls[column] = scroll
        return applyRow(effects)
    }

    private func applyRow(_ effects: ColumnScrollEffects) -> Bool {
        refreshRowShift()
        applyPresentation()
        if let pane = effects.focus { context.model.focus(pane, source: .scroll) }
        return effects.needsFrames
    }
}
