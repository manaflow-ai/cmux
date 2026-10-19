import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-19: "the spinner should NOT have a background". A row's badge draws each glyph on a
/// disc of the row's backdrop (the corner badge's cut-out ring) or a tonal chip (the stack). A
/// working or loading item is a bare spinner on the row's own background: no ring, no chip. Its cell
/// keeps its size and place, so nothing moves when it turns into the waiting, error or done glyph.
@MainActor @Suite struct RowBadgeBareSpinnerTests {
    private static func badge(_ states: [StatusIndicatorState], _ look: RowBadgeView.Look) -> RowBadgeView {
        let view = RowBadgeView(frame: NSRect(x: 0, y: 0, width: 60, height: 18))
        view.configure(states, look: look)
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test(arguments: [RowBadgeView.Look.corner, .stack], [StatusIndicatorState.working, .busy])
    func aSpinnerDrawsWithNoDiscBehindIt(look: RowBadgeView.Look, spinning: StatusIndicatorState) {
        let view = Self.badge([spinning, .waiting], look)
        #expect(view.backdrops(at: 0).allSatisfy(\.isHidden), "the spinner sits on the row's own background")
        #expect(view.backdrops(at: 1).contains { !$0.isHidden }, "the waiting glyph keeps its disc")
    }

    @Test(arguments: [RowBadgeView.Look.corner, .stack])
    func theSpinnersCellStaysPutWhenItsStateChanges(look: RowBadgeView.Look) {
        let working = Self.badge([.working, .error], look)
        let done = Self.badge([.success, .error], look)
        #expect(working.glyphFrames == done.glyphFrames)
        #expect(working.preferredWidth == done.preferredWidth)
    }
}
