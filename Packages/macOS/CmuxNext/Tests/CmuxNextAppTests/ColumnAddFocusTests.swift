import AppKit
import CmuxNextActions
import CmuxNextLayout
@testable import CmuxNextPalette
import CmuxNextSettings
import CoreGraphics
import Testing

/// Columns (Lawrence 2026-10-28): New Column Left and Right, a search for "move column left"
/// also lists Focus Column Left, new columns open at two thirds of the viewport, and moving focus
/// between columns scrolls the least that shows the focused column whole.
@MainActor
struct ColumnAddFocusTests {
    // MARK: Palette

    @Test(arguments: [("move column left", ActionID("column.focusLeft")), ("move column right", ActionID("column.focusRight"))])
    func aMoveColumnSearchAlsoListsFocusColumn(query: String, focus: ActionID) async {
        _ = NSApplication.shared
        let registry = ActionRegistry.standard()
        for id: ActionID in ["column.moveLeft", "column.moveRight", "column.focusLeft", "column.focusRight"] { registry.bind(id) {} }
        let palette = PaletteController(registry: registry, sources: PaletteSources(), frecencyPersistence: nil)
        defer { palette.hide() }
        palette.show(.commands)
        await palette.model.settle()
        palette.model.send(.setQuery(query))
        await palette.model.settle()
        let ids = palette.model.rows.compactMap(\.item.actionID)
        #expect(ids.contains(focus), "\(query) lists \(ids)")
    }

    @Test func newColumnLeftAndRightAreBothListed() async {
        _ = NSApplication.shared
        let registry = ActionRegistry.standard()
        #expect(registry.descriptor(for: "newColumn")?.title == "New Column Right")
        #expect(registry.descriptor(for: "newColumnLeft")?.title == "New Column Left")
        #expect(registry.descriptor(for: "newColumnLeft")?.cliName == "pane new-column-left")
    }

    // MARK: Width

    /// With no `layout` keys, a new column is two thirds of the viewport, fixed: not the full
    /// width it copied from a full-width neighbor before.
    @Test func aNewColumnDefaultsToTwoThirds() {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(abs(snapshot.defaultColumnWidth - 2.0 / 3.0) < 0.0001)
        #expect(snapshot.newColumnWidth == .fixed)
        let wide = [LayoutColumn(id: "c0", width: 1, root: .leaf("p0")), LayoutColumn(id: "c1", width: 1, root: .leaf("p1"))]
        let plan = NewColumnWidth.plan(mode: snapshot.newColumnWidth, columns: wide, anchor: "c1", visible: ["c1"],
                                       fixedWidth: snapshot.defaultColumnWidth)
        #expect(abs(plan.width - 2.0 / 3.0) < 0.0001)
    }

    // MARK: Focus scroll

    /// Four two-thirds columns on a 1200 pt strip (800 pt each, 16 pt gaps).
    private static func strip() -> ColumnStrip {
        let columns = (0..<4).map { index in
            ColumnStrip.Column(id: ColumnID("c\(index)"), frame: CGRect(x: 16 + CGFloat(index) * 816, y: 0, width: 800, height: 800),
                               panes: [PaneID("p\(index)")])
        }
        return ColumnStrip(columns: columns, viewportWidth: 1200, contentWidth: 4 * 816 + 16, gap: 16)
    }

    /// Focus Column Right then Left: each scroll aligns the nearest edge, the least that shows the
    /// focused column whole; a column already whole does not scroll.
    @Test func focusingAColumnScrollsTheLeastThatShowsItWhole() {
        var state = ColumnScrollState()
        let strip = Self.strip()
        state.reduce(.sync(strip, focused: "p0", source: .keyboard, animated: false))
        #expect(state.spring.target == 0)
        state.reduce(.sync(strip, focused: "p1", source: .keyboard, animated: false))
        // c1 ends at 1632; with its 16 pt padding the view's right edge goes to 1648.
        #expect(abs(state.spring.target - (1648 - 1200)) < 0.5)
        #expect(strip.isFullyVisible(strip.columns[1].frame, at: state.spring.target))
        let atRight = state.spring.target
        state.reduce(.sync(strip, focused: "p0", source: .keyboard, animated: false))
        // c0's left edge with padding: 0.
        #expect(state.spring.target == 0)
        #expect(atRight - state.spring.target == 448)
        // Already whole: no scroll.
        state.reduce(.sync(strip, focused: "p0", source: .keyboard, animated: false))
        #expect(state.spring.target == 0)
    }
}
