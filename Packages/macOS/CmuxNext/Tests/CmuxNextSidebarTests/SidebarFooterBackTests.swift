import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// Leo (T3 Code ref, 2026-10-07): while the window shows a full-page
/// destination, the sidebar's footer becomes one wide Back button in the
/// same spot, a universal way back to where you were.
@MainActor @Suite(.serialized) struct SidebarFooterBackTests {
    private func sidebar() async -> SidebarView {
        let view = SidebarView(model: SidebarModel())
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
        await settle(view)
        return view
    }

    private func settle(_ view: SidebarView) async {
        for _ in 0..<10 { await Task.yield() }
        view.layoutSubtreeIfNeeded()
    }

    @Test func theFooterShowsItsItemsUntilADestinationOpens() async {
        let view = await sidebar()
        #expect(view.backButton.isHidden)
        #expect(!view.belowFade.isHidden)
    }

    @Test func aDestinationTurnsTheFooterIntoOneWideBackButton() async {
        let view = await sidebar()
        let footer = view.belowFade.frame
        view.model.showsBack = true
        await settle(view)
        #expect(!view.backButton.isHidden)
        #expect(view.belowFade.isHidden, "the footer's items give way to Back")
        let back = view.backButton.frame
        #expect(back.width >= view.bounds.width - Metrics.space3 * 2, "one wide button, not an icon")
        // In the footer's spot: centred on the bottom band, or at the bottom
        // edge when the band is empty (the minimal footer of a bare sidebar).
        if footer.height >= back.height {
            #expect(abs(back.midY - footer.midY) <= Metrics.space2, "in the footer's spot: back \(back), footer \(footer)")
        } else {
            #expect(abs(back.maxY - (view.bounds.height - Metrics.space2)) <= 1, "at the bottom edge: back \(back), bounds \(view.bounds)")
        }
        #expect(view.backButton.accessibilityLabel()?.isEmpty == false)
        view.model.showsBack = false
        await settle(view)
        #expect(view.backButton.isHidden)
        #expect(!view.belowFade.isHidden)
    }

    @Test func backRunsTheModelsBack() async {
        let view = await sidebar()
        var runs = 0
        view.model.onBack = { runs += 1 }
        view.model.showsBack = true
        await settle(view)
        view.backButton.performClick(nil)
        #expect(runs == 1)
    }

    @Test func backButtonCanReceiveKeyboardFocus() async {
        let view = await sidebar()
        view.model.showsBack = true
        await settle(view)
        #expect(!view.backButton.refusesFirstResponder, "Back is a navigation control, so keyboard focus must reach it")
        #expect(view.backButton.acceptsFirstResponder)
    }

    /// Drawing must not dirty the button again: setting its image or title in
    /// `updateLayer` redraws it every frame, which hung the whole test run.
    @Test func drawingTheBackButtonLeavesItClean() async {
        let view = await sidebar()
        view.model.showsBack = true
        await settle(view)
        view.backButton.needsDisplay = false
        view.backButton.updateLayer()
        #expect(!view.backButton.needsDisplay)
    }
}
