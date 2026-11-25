import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-11-05, on the sidebar's "Help Make cmux Faster?" hang-reports card: "why is the text under it? Also
/// giving negative space away ... the buttons and the subtitle text is in a different indentation level". The title
/// and detail started after the icon while the buttons started at the card's edge, the detail ended in "…" after two
/// lines, and the card's height never depended on its width. The card as the sidebar's slot sizes and places it, at
/// the sidebar widths people use: one leading edge for the title, detail and buttons, and every word and button whole.
@MainActor @Suite(.serialized) struct SidebarNoticeCardColumnTests {
    /// The hang-reports question as `HangReportsController` asks it (`SidebarAsks.ask`).
    static func hangReportsAsk() -> SidebarNoticeCard {
        var card = SidebarNoticeCard(
            id: "ask.hang-reports", symbol: "gauge.with.dots.needle.33percent", title: HangReportsStrings.askTitle,
            detail: HangReportsStrings.privacySummary,
            actions: [SidebarNoticeCard.Action(id: "yes", title: HangReportsStrings.askYes, prominent: true),
                      SidebarNoticeCard.Action(id: "no", title: HangReportsStrings.askNo)],
            dismissLabel: HangReportsStrings.askNo)
        card.awaitsAnswer = true
        return card
    }

    /// An agent's Cloud machine request: a symbol, a detail and list lines longer than one line.
    static let cloudAsk = SidebarNoticeCard(
        id: "ask.cloud", symbol: "cloud", title: "Create a Cloud Machine?",
        detail: "An agent in this window asks for a new Cloud machine to run its work on.",
        lines: ["claude in lane sidebar-notice-card-column wants a machine", "Image: the default cmux development image"],
        actions: [SidebarNoticeCard.Action(id: "yes", title: "Create", prominent: true), SidebarNoticeCard.Action(id: "no", title: "Not Now")],
        dismissLabel: "Not Now")

    /// `card` in its slot in a sidebar `sidebarWidth` wide: the slot's height, then its place above the footer.
    static func placed(_ card: SidebarNoticeCard, sidebarWidth: CGFloat) -> SidebarNoticeCardView {
        _ = NSApplication.shared
        let notice = SidebarNoticeCardView(motionPolicy: { MotionPolicy(speed: .fast, reduceMotion: true) })
        let slot = SidebarBottomCardSlot(update: SidebarUpdateCardView(), nowPlaying: SidebarNowPlayingCardView(),
                                         updated: SidebarUpdatedCardHost(), notice: notice)
        slot.show(SidebarBottomCards(update: nil, nowPlaying: nil, updated: nil, notice: card))
        let slotHeight = slot.height(width: sidebarWidth)
        slot.place(above: 2000, width: sidebarWidth, slotHeight: slotHeight)
        notice.layoutSubtreeIfNeeded()
        return notice
    }

    /// The card's label that shows `text`.
    static func label(_ text: String, in view: NSView) -> ChromeLabel? {
        if let label = view as? ChromeLabel, !label.isHidden, label.stringValue == text { return label }
        return view.subviews.lazy.compactMap { label(text, in: $0) }.first
    }

    /// `label` is tall enough for every line of its text wrapped at its width: nothing truncates.
    static func expectWhole(_ label: ChromeLabel, _ name: String, sidebarWidth: CGFloat) {
        let probe = ChromeLabel(wrappingLabelWithString: label.stringValue)
        probe.font = label.font
        let needs = ceil(probe.size(forWidth: label.frame.width).height)
        #expect(label.frame.height >= needs, "at a \(sidebarWidth) pt sidebar the \(name) has \(label.frame.height) pt for \(needs) pt of text")
    }

    @Test(arguments: [220, 240, 260] as [CGFloat])
    func theHangReportsCardsTitleDetailAndButtonsShareOneLeadingEdgeAndShowWhole(sidebarWidth: CGFloat) throws {
        let ask = Self.hangReportsAsk()
        let card = Self.placed(ask, sidebarWidth: sidebarWidth)
        let title = card.titleLabel
        let detail = try #require(Self.label(HangReportsStrings.privacySummary, in: card), "the detail shows")
        #expect(detail.frame.minX == title.frame.minX, "the detail starts at \(detail.frame.minX), the title at \(title.frame.minX)")
        #expect(card.actionButtons.count == 2)
        let first = try #require(card.actionButtons.first)
        #expect(first.frame.minX == title.frame.minX, "the buttons start at \(first.frame.minX), the title at \(title.frame.minX)")
        Self.expectWhole(title, "title", sidebarWidth: sidebarWidth)
        Self.expectWhole(detail, "detail", sidebarWidth: sidebarWidth)
        #expect(title.frame.maxY <= detail.frame.minY)
        for button in card.actionButtons {
            let text = ceil((button.title as NSString).size(withAttributes: [.font: SidebarUpdateButton.font]).width)
            #expect(button.frame.width >= text, "\(button.title) is cut to \(button.frame.width) pt for \(text) pt of title")
            #expect(button.frame.minX >= title.frame.minX && button.frame.maxX <= card.bounds.width,
                    "\(button.title) spans \(button.frame.minX)...\(button.frame.maxX) in a \(card.bounds.width) pt card")
            #expect(button.frame.minY >= detail.frame.maxY, "\(button.title) overlaps the detail")
            #expect(button.frame.maxY <= card.bounds.height, "\(button.title) ends at \(button.frame.maxY) under the \(card.bounds.height) pt card")
        }
    }

    @Test(arguments: [220, 260] as [CGFloat])
    func aCardsListLinesWrapInFullUnderItsDetail(sidebarWidth: CGFloat) throws {
        let card = Self.placed(Self.cloudAsk, sidebarWidth: sidebarWidth)
        let detail = try #require(Self.label(Self.cloudAsk.detail ?? "", in: card))
        var top = detail.frame.maxY
        for line in Self.cloudAsk.lines {
            let label = try #require(Self.label("• " + line, in: card), "the line \(line) shows")
            #expect(label.frame.minX == card.titleLabel.frame.minX)
            Self.expectWhole(label, "line \(line)", sidebarWidth: sidebarWidth)
            #expect(label.frame.minY >= top, "the line \(line) overlaps the row above it")
            top = label.frame.maxY
        }
        let buttons = card.actionButtons.map(\.frame)
        #expect(buttons.allSatisfy { $0.minY >= top && $0.maxY <= card.bounds.height })
    }

    /// Review F1 of #36835: the card keeps its last measure, so every token the rows are measured in is part of its
    /// key. `Metrics.space3` is the card's padding, inside which the detail spans; changing it must move the text.
    /// (It was `Metrics.space6`, the round cancel's side, until a7964659 moved Cancel to the title's row and let the
    /// detail span the card: Lawrence 2026-11-07, "cancel button is ugly not taking up full width here".)
    @Test func aChangedSpacingTokenMeasuresTheCardAgain() throws {
        _ = NSApplication.shared
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(DesignTunables.all)
        defer { _ = TunableStore.shared.set(ChromeTunables.space3.key, nil) }
        let notice = SidebarNoticeCard(id: "update.downloading", title: "Downloading Update", detail: "115.0 MB of 265.3 MB",
                                       progress: .fraction(0.4), trailing: SidebarNoticeCard.Trailing(id: "cancel", symbol: "xmark.circle.fill", label: "Cancel"))
        let card = SidebarNoticeCardView(motionPolicy: { MotionPolicy(speed: .fast, reduceMotion: true) })
        card.configure(notice)
        card.frame = NSRect(x: 0, y: 0, width: 240, height: card.height(for: notice, width: 240))
        card.layoutSubtreeIfNeeded()
        let detail = try #require(Self.label(notice.detail ?? "", in: card))
        let before = detail.frame.width
        try #require(TunableStore.shared.set(ChromeTunables.space3.key, .number(12)) == .number(12))
        card.needsLayout = true
        card.layoutSubtreeIfNeeded()
        #expect(detail.frame.width < before, "the detail kept \(detail.frame.width) pt after the padding grew (was \(before))")
    }
}
