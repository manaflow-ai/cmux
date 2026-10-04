import AppKit
import CmuxNextDesign

/// Vertical row scrolling (plans/cmux-next/rows.md, Viewport). Each column
/// whose rows overflow keeps its own `ColumnScrollState`, fed the column's
/// rows as a strip on the vertical axis (`ColumnStrip(rows:)`), so reveal,
/// camera anchor, snapping and focus-after-scroll are the column scroll
/// rules transposed (V1, V2). Offsets are client view state, never sent.
extension ScreenContentView {
    /// The presented vertical offset of each scrolling row column.
    var rowOffsets: [ColumnID: CGFloat] { rowScrolls.mapValues(\.spring.value) }

    func rowOffset(of pane: PaneID) -> CGFloat {
        baseGeometry.rowColumnOfPane[pane].flatMap { rowScrolls[$0]?.spring.value } ?? 0
    }

    func rowOffset(of kind: DividerHandleView.Kind) -> CGFloat {
        let column: ColumnID? = switch kind {
        case let .split(id): baseGeometry.rowColumnOfSplit[id]
        case let .rowEdge(id, _): id
        case .columnEdge: nil
        }
        return column.flatMap { rowScrolls[$0]?.spring.value } ?? 0
    }

    var rowsMoving: Bool {
        rowScrolls.values.contains { !$0.isGestureActive && ($0.spring.value != $0.spring.target || $0.spring.velocity != 0) }
    }

    /// The rows of each scrolling column as the reducer sees them.
    private func rowStrips() -> [ColumnID: ColumnStrip] {
        var result: [ColumnID: ColumnStrip] = [:]
        for (id, stack) in baseGeometry.rowStacks where stack.scrolls {
            guard let column = layout.columns.first(where: { $0.id == id }) else { continue }
            result[id] = ColumnStrip(rows: stack, column: column, panes: baseGeometry.panes)
        }
        return result
    }

    /// Feeds every row column the current rows and focus (called with each
    /// `syncScroll`). A column that stops overflowing drops its offset.
    /// Returns true if a spring needs frames.
    @discardableResult
    func syncRows(focused: PaneID?, source: ColumnFocusSource, animated: Bool, reveals: Bool) -> Bool {
        let strips = rowStrips()
        var needsFrames = false
        for id in rowScrolls.keys where strips[id] == nil { rowScrolls[id] = nil }
        for (id, strip) in strips {
            var state = rowScrolls[id] ?? ColumnScrollState()
            let effects = state.reduce(.sync(strip, focused: focused, source: source, animated: animated, reveals: reveals))
            rowScrolls[id] = state
            if effects.needsFrames { needsFrames = true }
        }
        refreshRowShift()
        return needsFrames
    }

    /// Steps the row springs; true while one moves.
    func stepRows(_ dt: Double) -> Bool {
        var moving = false
        for id in Array(rowScrolls.keys) where rowScrolls[id]?.isGestureActive == false {
            if rowScrolls[id]!.spring.advance(dt, parameters: Motion.spring(.scroll), epsilon: 0.25) { moving = true }
        }
        if !rowScrolls.isEmpty { refreshRowShift() }
        return moving
    }

    /// Recomputes what hit testing reads from the presented row offsets.
    func refreshRowShift() {
        geometry = baseGeometry.shiftingRows(rowOffsets)
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
            let fixed = geometry.sticky.contains { $0.column == id }
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
        rowScrolls[column]?.reduce(.gestureBegan)
    }

    /// A trackpad delta (points; positive moves content down, as AppKit
    /// reports it).
    func rowScroll(_ column: ColumnID, deltaY: CGFloat, timestamp: TimeInterval) {
        rowScrolls[column]?.reduce(.gestureChanged(deltaX: deltaY, time: timestamp))
        refreshRowShift()
        applyPresentation()
    }

    @discardableResult
    func endRowScroll(_ column: ColumnID, timestamp: TimeInterval) -> Bool {
        guard var state = rowScrolls[column] else { return false }
        let effects = state.reduce(.gestureEnded(time: timestamp, animated: !context.reduceMotion))
        rowScrolls[column] = state
        return applyRow(effects)
    }

    /// One mouse wheel notch on the vertical axis.
    @discardableResult
    func discreteRowScroll(_ column: ColumnID, direction: Int) -> Bool {
        guard var state = rowScrolls[column] else { return false }
        let effects = state.reduce(.wheel(direction: direction, animated: !context.reduceMotion))
        rowScrolls[column] = state
        return applyRow(effects)
    }

    private func applyRow(_ effects: ColumnScrollEffects) -> Bool {
        refreshRowShift()
        applyPresentation()
        if let pane = effects.focus { context.model.focus(pane, source: .scroll) }
        return effects.needsFrames
    }
}

extension ColumnStrip {
    /// The rows of one column as a strip on the vertical axis: x and y
    /// swapped, measured from the column's top, so the column scroll rules
    /// apply to rows unchanged (rows.md V1, V2). Strip column ids carry
    /// the row ids.
    init(rows stack: RowStackGeometry, column: LayoutColumn, panes: [PaneID: CGRect]) {
        let top = stack.frame.minY
        func transposed(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minY - top, y: rect.minX, width: rect.height, height: rect.width)
        }
        let columns = zip(column.rows, stack.rows).map { row, placed in
            let rowPanes = row.root.panes
            var frames: [PaneID: CGRect] = [:]
            for pane in rowPanes { frames[pane] = panes[pane].map(transposed) }
            return Column(id: ColumnID(row.id.rawValue), frame: transposed(placed.frame), panes: rowPanes, paneFrames: frames)
        }
        self.init(columns: columns, viewportWidth: stack.frame.height, contentWidth: stack.contentHeight, gap: stack.gap)
    }
}
