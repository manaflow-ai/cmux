import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// BOTTOM-LEFT-CARDS K1 + Lawrence 2026-10-09: one shared notice card for
/// messages to the user (the "Did you know" tip, the update status) sits in
/// the update card's slot above the footer, one card at a time (the update
/// card wins), and the footer controls never move when it comes or goes.
@MainActor @Suite(.serialized) struct SidebarNoticeCardTests {
    static let tip = SidebarNoticeCard(id: "tip:commandPalette", eyebrow: "Did you know?", title: "Command Palette",
                                       detail: "Run any cmux action by typing its name.",
                                       actions: [.init(id: "try", title: "Try It")], shortcut: "⇧⌘P",
                                       dismissLabel: "Hide This Tip")
    static let upToDate = SidebarNoticeCard(id: "update", symbol: "checkmark.circle", title: "cmux Is Up to Date",
                                            detail: "Version 1.0.0-nightly.3752664687401, checked just now",
                                            dismissLabel: "Dismiss")
    static let available = SidebarNoticeCard(id: "update", symbol: "arrow.down.circle", title: "cmux 1.0.1 Is Available",
                                             detail: "You have 1.0.0.",
                                             actions: [.init(id: "update", title: "Update", prominent: true),
                                                       .init(id: "release_notes", title: "Release Notes")],
                                             dismissLabel: "Dismiss")

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
        #expect(view.noticeCardView.isHidden && view.noticeCardView.frame == .zero)
        view.model.noticeCard = Self.tip
        await settle(view) { view.noticeCardView.notice == Self.tip }
        let card = view.noticeCardView
        #expect(!card.isHidden)
        #expect(card.frame.height == SidebarNoticeCardView.height(for: Self.tip))
        #expect(card.frame.maxY <= view.footer.frame.minY)
        #expect(view.footer.frame == footer, "the footer controls stay where they were")
        #expect(card.shownText == ["Did you know?", "Command Palette", "Run any cmux action by typing its name.", "Try It", "⇧⌘P"])
        view.model.noticeCard = nil
        await settle(view) { view.noticeCardView.notice == nil }
        #expect(card.isHidden && card.frame == .zero)
        #expect(view.footer.frame == footer)
    }

    @Test func theUpdateCardWinsTheSlot() async {
        let view = sidebar()
        view.model.noticeCard = Self.tip
        view.model.updateCard = SidebarUpdateCardTests.card
        await settle(view) { view.updateCardView.card != nil && view.noticeCardView.notice != nil }
        #expect(!view.updateCardView.isHidden && view.updateCardView.frame.height > 0)
        #expect(view.noticeCardView.isHidden && view.noticeCardView.frame == .zero)
    }

    @Test func tryAndDismissSendTheirIntents() async {
        var intents: [SidebarIntent] = []
        let view = sidebar { intents.append($0) }
        view.model.noticeCard = Self.tip
        await settle(view) { view.noticeCardView.notice != nil }
        view.noticeCardView.actionButtons.first?.press()
        view.noticeCardView.closeButton.onPress?()
        #expect(intents == [.noticeAction(card: "tip:commandPalette", action: "try"), .dismissNotice("tip:commandPalette")])
        #expect(view.noticeCardView.closeButton.accessibilityLabel() == "Hide This Tip")
    }

    /// Lawrence 2026-10-09: the update status is the same notice card: its
    /// icon, title, one detail line and x; no button row without actions.
    @Test func anUpdateNoticeUsesTheSameCard() async {
        var intents: [SidebarIntent] = []
        let view = sidebar { intents.append($0) }
        let footer = view.footer.frame
        view.model.noticeCard = Self.upToDate
        await settle(view) { view.noticeCardView.notice == Self.upToDate }
        let card = view.noticeCardView
        #expect(!card.isHidden && card.showsSymbol)
        #expect(card.shownText == ["cmux Is Up to Date", "Version 1.0.0-nightly.3752664687401, checked just now"])
        #expect(card.frame.height == SidebarNoticeCardView.height(for: Self.upToDate))
        #expect(SidebarNoticeCardView.height(for: Self.upToDate) < SidebarNoticeCardView.height(for: Self.tip), "no empty button row")
        #expect(view.footer.frame == footer)
        card.closeButton.onPress?()
        #expect(intents == [.dismissNotice("update")])
        #expect(card.closeButton.accessibilityLabel() == "Dismiss")
    }

    @Test func anAvailableUpdateShowsItsActions() async {
        var intents: [SidebarIntent] = []
        let view = sidebar { intents.append($0) }
        view.model.noticeCard = Self.available
        await settle(view) { view.noticeCardView.notice == Self.available }
        let card = view.noticeCardView
        #expect(card.actionButtons.map(\.title) == ["Update", "Release Notes"])
        #expect(!card.actionButtons[0].isQuiet && card.actionButtons[1].isQuiet, "Update is the prominent action")
        card.actionButtons[0].press()
        card.actionButtons[1].press()
        #expect(intents == [.noticeAction(card: "update", action: "update"), .noticeAction(card: "update", action: "release_notes")])
    }

    /// cx-367y: the card floats on Liquid Glass with the theme tint, and
    /// Reduce Transparency turns it into an opaque theme fill, live.
    @Test func theCardIsGlassAndOpaqueUnderReduceTransparency() {
        let reduce = ReduceTransparency(system: { false }, changes: NotificationCenter())
        let card = SidebarNoticeCardView(reduceTransparency: reduce)
        card.configure(Self.tip)
        card.frame = NSRect(x: 0, y: 0, width: 236, height: SidebarNoticeCardView.height(for: Self.tip))
        card.layoutSubtreeIfNeeded()
        #expect(card.surface.frame == card.bounds)
        #expect(card.surface.material == OverlayMaterial.select(liquidGlassAvailable: OverlayMaterial.liquidGlassAvailable, reduceTransparency: false))
        let surfaceIndex = card.subviews.firstIndex(of: card.surface) ?? .max
        let linesIndex = card.subviews.firstIndex { card.actionButtons[0].isDescendant(of: $0) } ?? -1
        #expect(linesIndex > surfaceIndex, "the lines sit above the glass")
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
        let card = SidebarNoticeCardView(reduceTransparency: reduce)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 300, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView?.addSubview(card)
        card.configure(Self.tip)
        card.frame = NSRect(x: 8, y: 8, width: 236, height: SidebarNoticeCardView.height(for: Self.tip))
        for _ in 0..<5 {
            window.contentView?.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        for view in card.actionButtons + [card.closeButton] + card.lineViews {
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

