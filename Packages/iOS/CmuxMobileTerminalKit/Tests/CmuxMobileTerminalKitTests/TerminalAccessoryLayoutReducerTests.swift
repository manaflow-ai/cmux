import Foundation
import Testing

@testable import CmuxMobileTerminalKit

@Suite("TerminalAccessoryLayoutReducer")
struct TerminalAccessoryLayoutReducerTests {
    private let reducer = TerminalAccessoryLayoutReducer(configurable: [0, 1, 2, 3])

    @Test("first launch shows everything in canonical order")
    func firstLaunch() {
        let layout = reducer.load(savedOrder: [], savedEnabled: nil)
        #expect(layout.order == [0, 1, 2, 3])
        #expect(layout.enabled == Set([0, 1, 2, 3]))
        #expect(layout.visibleOrder == [0, 1, 2, 3])
    }

    @Test("saved order is honored, then missing actions append (forward-compat)")
    func savedOrderForwardCompat() {
        let layout = reducer.load(savedOrder: [2, 0], savedEnabled: [2, 0])
        #expect(layout.order == [2, 0, 1, 3])
        #expect(layout.visibleOrder == [2, 0])
    }

    @Test("unknown identifiers are dropped from saved order and enabled")
    func dropsUnknown() {
        let layout = reducer.load(savedOrder: [99, 1, 0], savedEnabled: [99, 1])
        #expect(layout.order == [1, 0, 2, 3])
        #expect(layout.enabled == Set([1]))
    }

    @Test("empty saved enabled means user hid everything, not first launch")
    func emptyEnabledIsHonored() {
        let layout = reducer.load(savedOrder: [0, 1, 2, 3], savedEnabled: [])
        #expect(layout.enabled.isEmpty)
        #expect(layout.visibleOrder.isEmpty)
    }

    @Test("setEnabled toggles visibility and ignores unknown identifiers")
    func setEnabled() {
        var layout = reducer.defaultLayout()
        layout = reducer.setEnabled(1, false, in: layout)
        #expect(layout.visibleOrder == [0, 2, 3])
        layout = reducer.setEnabled(1, true, in: layout)
        #expect(layout.visibleOrder == [0, 1, 2, 3])
        let unchanged = reducer.setEnabled(99, false, in: layout)
        #expect(unchanged == layout)
    }

    @Test("move reorders within the configurable region")
    func move() {
        var layout = reducer.defaultLayout()
        layout = reducer.move(from: IndexSet(integer: 0), to: 4, in: layout)
        #expect(layout.order == [1, 2, 3, 0])
        #expect(layout.enabled == Set([0, 1, 2, 3]))
    }

    @Test("defaultLayout is canonical order, all enabled")
    func defaultLayout() {
        let layout = reducer.defaultLayout()
        #expect(layout.order == [0, 1, 2, 3])
        #expect(layout.enabled == Set([0, 1, 2, 3]))
    }

    @Test("a custom default order drives the fresh-install layout")
    func customDefaultOrderFirstLaunch() {
        let curated = TerminalAccessoryLayoutReducer(configurable: [0, 1, 2, 3], defaultOrder: [2, 3, 0, 1])
        let layout = curated.load(savedOrder: [], savedEnabled: nil)
        #expect(layout.order == [2, 3, 0, 1])
        #expect(layout.enabled == Set([0, 1, 2, 3]))
        #expect(layout.visibleOrder == [2, 3, 0, 1])
    }

    @Test("a default order omitting an id appends it so nothing vanishes")
    func defaultOrderAppendsOmitted() {
        let curated = TerminalAccessoryLayoutReducer(configurable: [0, 1, 2, 3], defaultOrder: [2, 0])
        // Omitted 1 and 3 are appended in canonical order, never dropped.
        #expect(curated.defaultOrder == [2, 0, 1, 3])
        let layout = curated.defaultLayout()
        #expect(layout.order == [2, 0, 1, 3])
        #expect(layout.visibleOrder == [2, 0, 1, 3])
    }

    @Test("a default order with unknown ids drops them")
    func defaultOrderDropsUnknown() {
        let curated = TerminalAccessoryLayoutReducer(configurable: [0, 1, 2, 3], defaultOrder: [9, 2, 0, 7])
        #expect(curated.defaultOrder == [2, 0, 1, 3])
    }

    @Test("forward-compat append follows the default order, not canonical")
    func forwardCompatUsesDefaultOrder() {
        let curated = TerminalAccessoryLayoutReducer(configurable: [0, 1, 2, 3], defaultOrder: [3, 2, 1, 0])
        let layout = curated.load(savedOrder: [2, 0], savedEnabled: [2, 0])
        // Saved [2, 0] honored, then missing 3 and 1 appended in default order.
        #expect(layout.order == [2, 0, 3, 1])
        #expect(layout.visibleOrder == [2, 0])
    }

    @Test("saved rows are honored and missing actions append to the last row")
    func savedRowsForwardCompat() {
        let layout = reducer.load(savedRows: [[2, 0], [1]], savedEnabled: [2, 1], rowCount: 2)
        #expect(layout.rows == [[2, 0], [1, 3]])
        #expect(layout.visibleRows == [[2], [1]])
        #expect(layout.order == [2, 0, 1, 3])
    }

    @Test("empty rows are preserved so row count persists")
    func emptyRowsPersist() {
        let layout = reducer.load(savedRows: [[2], []], savedEnabled: nil, rowCount: 3)
        #expect(layout.rows == [[2], [], [0, 1, 3]])
        #expect(layout.visibleRows == [[2], [], [0, 1, 3]])
    }

    @Test("row count reduction merges overflow rows into the last retained row")
    func reducingRowCountMergesOverflow() {
        let layout = TerminalAccessoryLayoutReducer<Int>.Layout(
            rows: [[0], [1, 2], [3]],
            enabled: Set([0, 1, 2, 3])
        )
        let reduced = reducer.setRowCount(2, in: layout)
        #expect(reduced.rows == [[0], [1, 2, 3]])
    }

    @Test("row count increase appends empty rows")
    func increasingRowCountAppendsEmptyRows() {
        let layout = TerminalAccessoryLayoutReducer<Int>.Layout(
            rows: [[0, 1, 2, 3]],
            enabled: Set([0, 1, 2, 3])
        )
        let expanded = reducer.setRowCount(3, in: layout)
        #expect(expanded.rows == [[0, 1, 2, 3], [], []])
    }

    @Test("row-local move reorders only that row")
    func rowLocalMove() {
        let layout = TerminalAccessoryLayoutReducer<Int>.Layout(
            rows: [[0, 1], [2, 3]],
            enabled: Set([0, 1, 2, 3])
        )
        let moved = reducer.move(from: IndexSet(integer: 0), to: 2, inRow: 1, in: layout)
        #expect(moved.rows == [[0, 1], [3, 2]])
    }

    @Test("scoped reorder preserves terminal rows and non-scoped positions")
    func scopedReorderPreservesRows() {
        let scopedReducer = TerminalAccessoryLayoutReducer(configurable: [0, 1, 2, 3, 4, 5])
        let layout = TerminalAccessoryLayoutReducer<Int>.Layout(
            rows: [[0, 1, 2], [3, 4, 5]],
            enabled: Set([0, 1, 2, 3, 4, 5])
        )

        let moved = scopedReducer.reorder([5, 3, 0, 2], limitedTo: Set([0, 2, 3, 5]), in: layout)

        #expect(moved.rows == [[0, 1, 2], [5, 4, 3]])
        #expect(moved.enabled == layout.enabled)
    }

    @Test("moving an item to another row preserves enabled state")
    func moveItemToRow() {
        let layout = TerminalAccessoryLayoutReducer<Int>.Layout(
            rows: [[0, 1], [2, 3]],
            enabled: Set([0, 2])
        )
        let moved = reducer.move(1, toRow: 1, in: layout)
        #expect(moved.rows == [[0], [2, 3, 1]])
        #expect(moved.enabled == Set([0, 2]))
    }
}
