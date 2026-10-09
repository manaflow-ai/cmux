import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// The "cmux Updated!" card (cx-7py7) in the bottom-left card slot: on the
/// tip card's glass, above the footer. A staged update wins the slot, then
/// the Updated card, then the tip, which waits.
@MainActor @Suite(.serialized) struct SidebarUpdatedCardTests {
    static let card = SidebarUpdatedCard(title: "cmux Updated!", whatsNewTitle: "See What's New", shareTitle: "Share cmux",
                                         dismissLabel: "Hide Until the Next Update")

    private func sidebar(intents: ((SidebarIntent) -> Void)? = nil) -> SidebarView {
        let model = SidebarModel()
        model.onIntent = intents
        let view = SidebarView(model: model)
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 700)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func settle(_ view: SidebarView, until done: () -> Bool) async {
        for _ in 0..<200 where !done() { await Task.yield() }
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
    }

    @Test func theCardShowsAboveTheFooterAndTheFooterNeverMoves() async {
        let view = sidebar()
        let footer = view.footer.frame
        #expect(view.updatedCardView.isHidden && view.updatedCardView.frame == .zero)
        view.model.updatedCard = Self.card
        await settle(view) { view.updatedCardView.card == Self.card }
        let card = view.updatedCardView
        #expect(!card.isHidden)
        #expect(card.frame.height == SidebarUpdatedCardView.height)
        #expect(card.frame.maxY <= view.footer.frame.minY)
        #expect(view.footer.frame == footer)
        #expect(card.shownText == ["cmux Updated!", "See What's New", "Share cmux"])
        view.model.updatedCard = nil
        await settle(view) { view.updatedCardView.card == nil }
        #expect(card.isHidden && card.frame == .zero)
    }

    @Test func theUpdatedCardWinsTheSlotOverTheTip() async {
        let view = sidebar()
        view.model.tipCard = SidebarTipCardTests.tip
        view.model.updatedCard = Self.card
        await settle(view) { view.updatedCardView.card != nil && view.tipCardView.tip != nil }
        #expect(!view.updatedCardView.isHidden && view.updatedCardView.frame.height > 0)
        #expect(view.tipCardView.isHidden && view.tipCardView.frame == .zero, "the tip waits")
        view.model.updatedCard = nil
        await settle(view) { view.updatedCardView.card == nil }
        #expect(!view.tipCardView.isHidden, "the tip comes back once the card goes")
    }

    @Test func aStagedUpdateWinsOverTheUpdatedCard() async {
        let view = sidebar()
        view.model.updatedCard = Self.card
        view.model.updateCard = SidebarUpdateCardTests.card
        await settle(view) { view.updateCardView.card != nil && view.updatedCardView.card != nil }
        #expect(!view.updateCardView.isHidden)
        #expect(view.updatedCardView.isHidden && view.updatedCardView.frame == .zero)
    }

    @Test func theRowsAndTheXSendTheirIntents() async {
        var intents: [SidebarIntent] = []
        let view = sidebar { intents.append($0) }
        view.model.updatedCard = Self.card
        await settle(view) { view.updatedCardView.card != nil }
        view.updatedCardView.whatsNewRow.onPress?()
        view.updatedCardView.shareRow.onPress?()
        view.updatedCardView.closeButton.onPress?()
        #expect(intents == [.openWhatsNew, .shareCmux, .dismissUpdated])
        #expect(view.updatedCardView.closeButton.accessibilityLabel() == "Hide Until the Next Update")
        #expect(view.updatedCardView.whatsNewRow.accessibilityLabel() == "See What's New")
        #expect(view.updatedCardView.shareRow.accessibilityRole() == .button)
    }

    /// Same material as the tip card (cx-367y): glass, the lines above it,
    /// opaque under Reduce Transparency.
    @Test func theCardIsGlassWithTheLinesAboveIt() {
        let reduce = ReduceTransparency(system: { false }, changes: NotificationCenter())
        let card = SidebarUpdatedCardView(reduceTransparency: reduce)
        card.configure(Self.card)
        card.frame = NSRect(x: 0, y: 0, width: 236, height: SidebarUpdatedCardView.height)
        card.layoutSubtreeIfNeeded()
        #expect(card.surface.frame == card.bounds)
        let surfaceIndex = card.subviews.firstIndex(of: card.surface) ?? .max
        let linesIndex = card.subviews.firstIndex { card.shareRow.isDescendant(of: $0) } ?? -1
        #expect(linesIndex > surfaceIndex, "the lines sit above the glass")
        reduce.override = true
        #expect(card.surface.material == .opaque)
        reduce.override = nil
    }
}
