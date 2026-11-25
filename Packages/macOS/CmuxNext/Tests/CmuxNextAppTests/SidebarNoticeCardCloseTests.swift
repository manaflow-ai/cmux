import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The notice card's close x sits in the card's top trailing corner, concentric with it (Lawrence 2026-11-15: a card's x
/// must be concentric with its corner; it sat on the heading's cap center before, live-qa 2026-10-21), with or without
/// a heading: the same inset from the top and the side (CardCloseConcentricTests measures the corner).
@MainActor @Suite(.serialized) struct SidebarNoticeCardCloseTests {
    private func laidOut(_ notice: SidebarNoticeCard) -> SidebarNoticeCardView {
        _ = NSApplication.shared
        let card = SidebarNoticeCardView(frame: NSRect(x: 0, y: 0, width: 216, height: SidebarNoticeCardView.height(for: notice, width: 216)))
        card.configure(notice)
        card.layoutSubtreeIfNeeded()
        return card
    }

    @Test(arguments: [SidebarNoticeCard(id: "tip", eyebrow: "Did you know?", title: "Command Palette", dismissLabel: "Close"),
                      SidebarNoticeCard(id: "note", title: "Command Palette", dismissLabel: "Close")])
    func theCloseXSitsInTheCardsCorner(notice: SidebarNoticeCard) {
        let card = laidOut(notice)
        #expect(!card.closeButton.isHidden, "the card shows its x")
        let close = card.convert(card.closeButton.frame, from: card.closeButton.superview)
        #expect(abs(close.minY - (card.bounds.maxX - close.maxX)) <= 0.5, "\(notice.id): the x \(close) in \(card.bounds)")
    }

    /// The title never runs under the x.
    @Test func theTitleStopsBeforeTheX() {
        let card = laidOut(SidebarNoticeCard(id: "long", title: "Command Palette runs every cmux action by its name", dismissLabel: "Close"))
        let close = card.convert(card.closeButton.frame, from: card.closeButton.superview)
        let title = card.convert(card.titleLabel.frame, from: card.titleLabel.superview)
        #expect(!title.intersects(close), "the title \(title) runs under the x \(close)")
    }
}
