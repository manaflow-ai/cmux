import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The notice card's close x sits on its first line's cap center (live-qa 2026-10-21: the x sat
/// about a point above the "Did you know?" heading's cap center).
@MainActor @Suite(.serialized) struct SidebarNoticeCardCloseTests {
    private func laidOut(_ notice: SidebarNoticeCard) -> SidebarNoticeCardView {
        _ = NSApplication.shared
        let card = SidebarNoticeCardView(frame: NSRect(x: 0, y: 0, width: 216, height: SidebarNoticeCardView.height(for: notice)))
        card.configure(notice)
        card.layoutSubtreeIfNeeded()
        return card
    }

    private func capCenter(of label: ChromeLabel, in card: SidebarNoticeCardView) -> CGFloat {
        let frame = card.convert(label.frame, from: label.superview)
        return frame.minY + label.firstBaselineOffsetFromTop - (label.font?.capHeight ?? 0) / 2
    }

    @Test func theCloseXSitsOnTheHeadingsCapCenter() {
        let card = laidOut(SidebarNoticeCard(id: "tip", eyebrow: "Did you know?", title: "Command Palette", dismissLabel: "Close"))
        #expect(!card.closeButton.isHidden, "the card shows its x")
        let close = card.convert(card.closeButton.frame, from: card.closeButton.superview)
        let cap = capCenter(of: card.eyebrowLabel, in: card)
        #expect(abs(close.midY - cap) <= 0.5, "the x's center \(close.midY), the heading's cap center \(cap)")
    }

    @Test func withoutAHeadingTheCloseXSitsOnTheTitlesCapCenter() {
        let card = laidOut(SidebarNoticeCard(id: "note", title: "Command Palette", dismissLabel: "Close"))
        #expect(!card.closeButton.isHidden, "the card shows its x")
        let close = card.convert(card.closeButton.frame, from: card.closeButton.superview)
        let cap = capCenter(of: card.titleLabel, in: card)
        #expect(abs(close.midY - cap) <= 0.5, "the x's center \(close.midY), the title's cap center \(cap)")
    }
}
