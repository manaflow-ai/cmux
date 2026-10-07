import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// BOTTOM-LEFT-CARDS K1: the "Did you know" card sits in the update card's
/// slot above the footer, one card at a time (the update card wins), and
/// the footer controls never move when it comes or goes.
@MainActor @Suite(.serialized) struct SidebarTipCardTests {
    static let tip = SidebarTipCard(id: "commandPalette", eyebrow: "Did you know?", title: "Command Palette",
                                    benefit: "Run any cmux action by typing its name.", shortcut: "⇧⌘P",
                                    tryTitle: "Try It", dismissLabel: "Hide This Tip")

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

    @Test func aTipShowsAboveTheFooterAndTheFooterNeverMoves() async {
        let view = sidebar()
        let footer = view.footer.frame
        #expect(view.tipCardView.isHidden && view.tipCardView.frame == .zero)
        view.model.tipCard = Self.tip
        await settle(view) { view.tipCardView.tip == Self.tip }
        let card = view.tipCardView
        #expect(!card.isHidden)
        #expect(card.frame.height == SidebarTipCardView.height)
        #expect(card.frame.maxY <= view.footer.frame.minY)
        #expect(view.footer.frame == footer, "the footer controls stay where they were")
        #expect(card.shownText == ["Did you know?", "Command Palette", "Run any cmux action by typing its name.", "Try It", "⇧⌘P"])
        view.model.tipCard = nil
        await settle(view) { view.tipCardView.tip == nil }
        #expect(card.isHidden && card.frame == .zero)
        #expect(view.footer.frame == footer)
    }

    @Test func theUpdateCardWinsTheSlot() async {
        let view = sidebar()
        view.model.tipCard = Self.tip
        view.model.updateCard = SidebarUpdateCardTests.card
        await settle(view) { view.updateCardView.card != nil && view.tipCardView.tip != nil }
        #expect(!view.updateCardView.isHidden && view.updateCardView.frame.height > 0)
        #expect(view.tipCardView.isHidden && view.tipCardView.frame == .zero)
    }

    @Test func tryAndDismissSendTheirIntents() async {
        var intents: [SidebarIntent] = []
        let view = sidebar { intents.append($0) }
        view.model.tipCard = Self.tip
        await settle(view) { view.tipCardView.tip != nil }
        view.tipCardView.tryButton.press()
        view.tipCardView.closeButton.onPress?()
        #expect(intents == [.tryTip("commandPalette"), .dismissTip("commandPalette")])
        #expect(view.tipCardView.closeButton.accessibilityLabel() == "Hide This Tip")
    }
}
