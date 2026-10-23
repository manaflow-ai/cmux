import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// A scroll of the palette's list slides rows under a resting pointer, and the list re-hit-tests
/// hover on every scroll tick (`PaletteListView.boundsChanged`), so the hovered row changes about
/// once per row height of travel: nearly every frame of a fling. The #6790 class (classic: a whole
/// window laid out per scroll tick) here was one render of the whole palette per hovered row: the
/// search bar re-applied and laid out, the chips, breadcrumb, tooltips and accessibility labels,
/// the footer, the menus. A hover change touches the two row views it moves between, nothing else.
///
/// Observation calls a tracker's `onChange` as the change happens, so the test reads at once
/// whether a hover change scheduled a whole-palette render, and runs the hover hop itself
/// (`applyScheduledHover()`), with no wait.
@MainActor
struct PaletteScrollHoverTests {
    @Test func aHoverChangeRendersOnlyTheRowsItMovesBetween() throws {
        _ = NSApplication.shared
        let model = PaletteModel()
        let content = PaletteContentView(model: model)
        for row in ["a", "b", "c", "d"] {
            model.hover(row)
            #expect(!content.renderScheduled, "hovering row \(row) scheduled a whole-palette render")
            try #require(content.hoverScheduled, "hovering row \(row) did not reach the list")
            content.applyScheduledHover()
            #expect(content.list.hoveredID == row)
        }
        // The query still renders the palette (its tracking is live).
        model.query = "x"
        #expect(content.renderScheduled)
    }
}
