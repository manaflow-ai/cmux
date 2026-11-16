import AppKit
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextSidebar
import Testing

/// A card's close x sits in its corner concentric with it (Lawrence 2026-11-15, on the "Updated to Nightly / What's new
/// in this build" card: the x was not concentric with the card's corner): the same inset from the top and from the
/// side, and its round hover shape the card's corner less that inset, the shared rule
/// (``ConcentricContainer/cornerControl(outerRadius:side:minimumPadding:)``). Measured on every dismissable card as
/// it lays out.
@MainActor @Suite(.serialized) struct CardCloseConcentricTests {
    /// What breaks the rule for the x at `close` (with `radius`) in the card at `card` rounded by `outer`.
    private static func broken(close: CGRect, radius: CGFloat, card: CGRect, outer: CGFloat) -> [String] {
        let side = card.maxX - close.maxX
        return ConcentricContainer.violations(child: close, childRadius: radius, in: card, outerRadius: outer, padding: side)
            + (side < 0 ? ["the x is \(side) pt past the card's side"] : [])
    }

    private static func radius(of button: SidebarIconButton) -> CGFloat {
        button.updateLayer()
        return button.layer?.cornerRadius ?? 0
    }

    @Test func theUpdatedCardsCloseIsConcentric() throws {
        _ = NSApplication.shared
        for anchor in [SidebarCardAnchor.top, .bottom] {
            let host = SidebarUpdatedCardHost(frame: NSRect(x: 0, y: 0, width: 216, height: 60))
            host.anchor = anchor
            host.layoutSubtreeIfNeeded()
            host.layout()
            let close = host.closeButton.frame
            let broken = Self.broken(close: close, radius: Self.radius(of: host.closeButton), card: host.bounds, outer: host.glass.cornerRadius)
            #expect(broken.isEmpty, "\(anchor): the x \(close) in \(host.bounds) r\(host.glass.cornerRadius): \(broken)")
        }
    }

    @Test(arguments: [SidebarNoticeCard(id: "tip", eyebrow: "Did you know?", title: "Command Palette", dismissLabel: "Close"),
                      SidebarNoticeCard(id: "note", title: "Command Palette", dismissLabel: "Close")])
    func theNoticeCardsCloseIsConcentric(notice: SidebarNoticeCard) throws {
        _ = NSApplication.shared
        let card = SidebarNoticeCardView(frame: NSRect(x: 0, y: 0, width: 216, height: SidebarNoticeCardView.height(for: notice, width: 216)))
        card.configure(notice)
        card.layoutSubtreeIfNeeded()
        let close = card.convert(card.closeButton.frame, from: card.closeButton.superview)
        let surface = card.convert(card.surface.bounds, from: card.surface)
        let broken = Self.broken(close: close, radius: Self.radius(of: card.closeButton), card: surface, outer: card.surface.cornerRadius)
        #expect(broken.isEmpty, "\(notice.id): the x \(close) in \(surface) r\(card.surface.cornerRadius): \(broken)")
    }

    @Test func theMediaCardsCloseIsConcentric() throws {
        _ = NSApplication.shared
        let track = NowPlayingCardTests.track()
        let card = SidebarNowPlayingCardView(frame: NSRect(x: 0, y: 0, width: 216, height: SidebarNowPlayingCardView.height(for: track)))
        card.configure(track)
        card.layoutSubtreeIfNeeded()
        let close = card.convert(card.closeButton.frame, from: card.closeButton.superview)
        let surface = card.convert(card.surface.bounds, from: card.surface)
        let broken = Self.broken(close: close, radius: Self.radius(of: card.closeButton), card: surface, outer: card.surface.cornerRadius)
        #expect(broken.isEmpty, "the x \(close) in \(surface) r\(card.surface.cornerRadius): \(broken)")
    }
}
