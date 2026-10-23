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
@MainActor
struct PaletteScrollHoverTests {
    /// Lets the palette's observation hop (one main-actor task per change) run, until `done` holds.
    private static func settle(until done: () -> Bool) async {
        for _ in 0..<100 where !done() { await Task.yield() }
    }

    @Test func aHoverChangeRendersOnlyTheRowsItMovesBetween() async throws {
        _ = NSApplication.shared
        let model = PaletteModel()
        let content = PaletteContentView(model: model)
        let rendered = content.renderCount
        for row in ["a", "b", "c", "d"] {
            model.hover(row)
            await Self.settle { content.list.hoveredID == row }
            try #require(content.list.hoveredID == row, "the list never drew row \(row) hovered")
        }
        #expect(content.renderCount == rendered, "\(content.renderCount - rendered) whole-palette renders for 4 hover changes")
        // The query still renders the palette (the count is live).
        model.query = "x"
        await Self.settle { content.renderCount > rendered }
        #expect(content.renderCount > rendered)
    }
}
