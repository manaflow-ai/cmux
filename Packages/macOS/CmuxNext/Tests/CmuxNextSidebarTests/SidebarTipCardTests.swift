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

    /// cx-367y: the card floats on Liquid Glass with the theme tint, and
    /// Reduce Transparency turns it into an opaque theme fill, live.
    @Test func theCardIsGlassAndOpaqueUnderReduceTransparency() {
        let reduce = ReduceTransparency(system: { false }, changes: NotificationCenter())
        let card = SidebarTipCardView(reduceTransparency: reduce)
        card.configure(Self.tip)
        card.frame = NSRect(x: 0, y: 0, width: 236, height: SidebarTipCardView.height)
        card.layoutSubtreeIfNeeded()
        #expect(card.surface.frame == card.bounds)
        #expect(card.surface.material == OverlayMaterial.select(liquidGlassAvailable: OverlayMaterial.liquidGlassAvailable, reduceTransparency: false))
        #expect(card.surface.isDescendant(of: card) && card.tryButton.isDescendant(of: card.surface), "the lines sit on the glass")
        reduce.override = true
        #expect(card.surface.material == .opaque)
        #expect(card.shownText.first == "Did you know?", "the lines survive the material change")
        reduce.override = nil
        #expect(card.surface.material != .opaque)
    }

    /// nxdog75: the glass card drew EMPTY (no title, text, Try It or x). Every line and button
    /// must have room and be visible inside the card, in a real window, on every SDK.
    @Test func theLinesAreVisibleInsideTheGlassCard() async throws {
        let reduce = ReduceTransparency(system: { false }, changes: NotificationCenter())
        let card = SidebarTipCardView(reduceTransparency: reduce)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 300, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView?.addSubview(card)
        card.configure(Self.tip)
        card.frame = NSRect(x: 8, y: 8, width: 236, height: SidebarTipCardView.height)
        for _ in 0..<5 {
            window.contentView?.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        for view in [card.tryButton, card.closeButton] + card.lineViews {
            #expect(!view.isHiddenOrHasHiddenAncestor)
            let shown = view.convert(view.visibleRect, to: card)
            #expect(shown.width >= 1 && shown.height >= 1, "\(type(of: view)) has room: visible \(view.visibleRect), frame \(view.frame)")
            var ancestor = view.superview
            while let current = ancestor, current !== card {
                #expect(!current.bounds.isEmpty, "no empty view between the line and the card: \(type(of: current)) \(current.frame)")
                ancestor = current.superview
            }
        }
    }
}

