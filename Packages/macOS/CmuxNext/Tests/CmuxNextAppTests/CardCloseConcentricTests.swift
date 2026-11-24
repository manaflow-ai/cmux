import AppKit
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextSidebar
import Testing

/// A card's close x keeps its shared concentric trailing inset and hover shape, while the Updated card's x stays on
/// the content row at every sidebar density. Measured on every dismissable card as it lays out.
@MainActor @Suite(.serialized) struct CardCloseConcentricTests {
    /// What breaks the rule for the x at `close` (with `radius`) in the top trailing corner of the card at `card`
    /// rounded by `outer`: the top and the side insets differ, or the x does not round by the corner less the inset.
    /// (The bottom is the card's text's: a one-line card is short, so the x sits nearer its bottom than its top.)
    private static func broken(close: CGRect, radius: CGFloat, card: CGRect, outer: CGFloat) -> [String] {
        let side = card.maxX - close.maxX
        // The card's top in either coordinate space: the edge the x is nearer.
        let top = min(close.minY - card.minY, card.maxY - close.maxY)
        let expected = max(0, min(outer - side, min(close.width, close.height) / 2))
        var out: [String] = []
        if side < 0 { out.append("the x is \(side) pt past the card's side") }
        if abs(top - side) > 0.5 { out.append("top inset \(top) is not the side inset \(side)") }
        if abs(radius - expected) > 0.5 { out.append("the x rounds by \(radius), not \(outer) - \(side) = \(expected)") }
        return out
    }

    private static func radius(of button: SidebarIconButton) -> CGFloat {
        button.updateLayer()
        return button.layer?.cornerRadius ?? 0
    }

    @Test func theUpdatedCardsCloseIsCenteredOnItsContentRow() throws {
        _ = NSApplication.shared
        for anchor in [SidebarCardAnchor.top, .bottom] {
            let host = SidebarUpdatedCardHost(frame: NSRect(x: 0, y: 0, width: 216, height: 60))
            host.anchor = anchor
            host.layoutSubtreeIfNeeded()
            host.layout()
            let close = host.closeButton.frame
            #expect(abs(close.midY - host.bounds.midY) <= 0.5, "\(anchor): the x is not on the content row: \(close)")
            #expect(close.width == SidebarUpdatedCardHost.closeSide)
            let side = host.bounds.maxX - close.maxX
            let corner = Metrics.cornerControl(outerRadius: host.glass.cornerRadius, side: SidebarUpdatedCardHost.closeSide)
            #expect(abs(side - corner.padding) <= 0.5, "\(anchor): the x's trailing inset is \(side), not \(corner.padding)")
            #expect(abs(Self.radius(of: host.closeButton) - corner.childRadius) <= 0.5)
        }
    }

    @Test(arguments: SidebarDensity.allCases)
    func theUpdatedCardsCloseHitTargetFollowsEveryDensity(density: SidebarDensity) {
        let base = SidebarRowTokens.Base(rowHeight: 24, space1: 2, space2: 4, space3: 6, space4: 8,
                                         cornerRadius: 6, body: 12, caption: 10.5)
        let side = SidebarRowTokens(density: density, textSize: .standard, base: base).card.closeSide
        let card = CGRect(x: 0, y: 0, width: 216, height: 48)
        let close = SidebarUpdatedCardHost.closeFrame(in: card, cornerRadius: LayoutGrid.cardRadius, side: side)

        #expect(close.width == side, "\(density): the x hit target is \(close.width), not \(side)")
        #expect(close.height == side)
        #expect(abs(close.midY - card.midY) <= 0.5, "\(density): the x is not centered on the content row: \(close)")
        #expect(close.maxX <= card.maxX)
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
