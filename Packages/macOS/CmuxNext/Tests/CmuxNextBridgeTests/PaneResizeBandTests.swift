import CmuxNextLayout
import Testing
@testable import CmuxNextBridge

/// Keyboard resize of a top or bottom dock (layout-model.md): up and down
/// move its inner edge, left and right do nothing without a split.
@Suite struct PaneResizeBandTests {
    private func layout(_ edge: StickyEdge) -> ScreenLayout {
        .columns([
            LayoutColumn(id: "a", width: 0.5, root: .leaf("pa")),
            LayoutColumn(id: "d", width: 0.3, root: .leaf("pd"), sticky: StickyColumn(edge: edge, mode: .docked)),
        ])
    }

    @Test func downGrowsATopDockAndUpGrowsABottomDock() {
        #expect(PaneResize.change(for: "pd", direction: .down, in: layout(.top)) == .columnWidth("d", 0.35))
        #expect(PaneResize.change(for: "pd", direction: .up, in: layout(.top)) == .columnWidth("d", 0.25))
        #expect(PaneResize.change(for: "pd", direction: .up, in: layout(.bottom)) == .columnWidth("d", 0.35))
    }

    @Test func leftAndRightDoNotResizeABand() {
        #expect(PaneResize.change(for: "pd", direction: .left, in: layout(.top)) == nil)
        #expect(PaneResize.change(for: "pd", direction: .right, in: layout(.bottom)) == nil)
    }
}
