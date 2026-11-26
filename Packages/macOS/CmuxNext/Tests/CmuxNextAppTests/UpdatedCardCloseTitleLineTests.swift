import AppKit
import CmuxNextDesign
import CmuxNextPages
import CmuxNextSettings
@testable import CmuxNextSidebar
import Testing

/// u51892 (2026-11-23, on the sidebar's "Updated to Nightly" card): "why the x icon is not aligned vertically
/// with the Updated to Nightly thing? let's put it on the right side in line with the Updated to Nightly ...
/// the stuff in this message box is now just cut off". The x took the corner's concentric inset from the
/// card's top, which sat it below the title's capitals, and further below once the card grew for its lines.
/// The page now reports its title line's middle (surface.tsx `cardTitleMid`) and the host centers its x on
/// it, at the corner's trailing inset, at every height the card grows to and either place it rests.
@MainActor
@Suite(.serialized)
struct UpdatedCardCloseTitleLineTests {
    final class FakeIsland: SidebarSurfaceIsland {
        let view = NSView()
        var contentHeight: CGFloat = 0
        var titleLineMid: CGFloat = 0
        var contentSettled = false
        var onHeightChange: (() -> Void)?
        var onAction: (() -> Void)?
        var onDismiss: (() -> Void)?
        func close() {}
        func report(height: CGFloat, title: CGFloat, settled: Bool = true) {
            (contentHeight, titleLineMid, contentSettled) = (height, title, settled)
            onHeightChange?()
        }
    }

    final class FakeSurfaces: SidebarUpdateSurfaces {
        var islands: [FakeIsland] = []
        func island(_ kind: SidebarUpdateSurfaceKind) -> any SidebarSurfaceIsland {
            let island = FakeIsland()
            islands.append(island)
            return island
        }
    }

    static let card = SidebarUpdatedCard(title: "Updated", whatsNewTitle: "See What's New", dismissLabel: "Close")

    /// A host showing the card, its page reporting `height` with its title line `title` down from the top.
    static func host(anchor: SidebarCardAnchor, height: CGFloat, title: CGFloat) throws -> SidebarUpdatedCardHost {
        _ = NSApplication.shared
        let host = SidebarUpdatedCardHost(frame: NSRect(x: 0, y: 0, width: 216, height: height))
        host.anchor = anchor
        let surfaces = FakeSurfaces()
        host.configure(card)
        host.surfaces = surfaces
        try #require(surfaces.islands.last).report(height: height, title: title)
        host.layoutSubtreeIfNeeded()
        host.layout()
        return host
    }

    // A one-line-box card (48), a card grown for a wrapped change line (66), and a tall one (92).
    @Test(arguments: [(CGFloat(48), CGFloat(17)), (66, 17), (92, 19.5)])
    func theXIsCenteredOnTheTitleLine(height: CGFloat, title: CGFloat) throws {
        for anchor in [SidebarCardAnchor.bottom, .top] {
            let host = try Self.host(anchor: anchor, height: height, title: title)
            let close = host.closeButton.frame
            let card = host.cardRect
            #expect(abs(close.midY - (card.minY + title)) < 0.01,
                    "\(anchor) \(height): the x's middle \(close.midY) is not the title line's \(card.minY + title)")
            // On the right, at the corner's trailing inset.
            #expect(abs(card.maxX - close.maxX - host.closeInset) < 0.01, "\(anchor) \(height): the x \(close) is not at the trailing inset")
            #expect(close.minY >= card.minY, "\(anchor) \(height): the x \(close) stands past the card's top")
        }
    }

    /// The card grows for its lines: the x stays on the title line, never drifting down with the card's middle.
    @Test func theXDoesNotFollowTheCardsGrowth() throws {
        let short = try Self.host(anchor: .bottom, height: 48, title: 17)
        let tall = try Self.host(anchor: .bottom, height: 92, title: 17)
        let fromTop = { (host: SidebarUpdatedCardHost) in host.closeButton.frame.midY - host.cardRect.minY }
        #expect(abs(fromTop(short) - fromTop(tall)) < 0.01)
    }

    /// Before the page reports its title line the x keeps the corner's concentric frame.
    @Test func withoutATitleLineTheXKeepsTheCorner() {
        let corner = NSRect(x: 190, y: 14, width: 20, height: 20)
        let card = NSRect(x: 0, y: 0, width: 216, height: 60)
        #expect(SidebarUpdatedCardHost.closeFrame(corner: corner, card: card, titleLineMid: 0) == corner)
        // A title line nearer the top than half the x never lifts it past the card's top.
        #expect(SidebarUpdatedCardHost.closeFrame(corner: corner, card: card, titleLineMid: 4).minY == 0)
        #expect(SidebarUpdatedCardHost.closeFrame(corner: corner, card: card, titleLineMid: 17).midY == 17)
    }

    /// The page's report carries the title line in CSS px: taken at the page's zoom without the sizes' round-up
    /// (a point up would sit the x off the line), and again at a new zoom.
    @Test func theReportedTitleLineFollowsTheZoom() {
        var size = PageSurfaceSize()
        let laid1 = size.take(height: 48, width: 0, overlay: 0, title: 17.25, zoom: 1)
        #expect(laid1)
        #expect(size.title == 17.25)
        let laid2 = size.take(height: 48, width: 0, overlay: 0, title: 17.25, zoom: 1)
        #expect(!laid2, "the same report lays nothing out again")
        let laid3 = size.take(height: 48, width: 0, overlay: 0, title: 18, zoom: 1)
        #expect(laid3, "a moved title line lays the card out again")
        let laid4 = size.rezoom(1.25)
        #expect(laid4)
        #expect(size.title == 22.5)
        #expect(size.height == 60)
    }

    /// Review F1: a taller card remembered from the last showing (82: a wrapped change) is held while the
    /// new words load, then gives its room back once they are final and shorter (48). While held, the
    /// page stands its words on the slot's bottom, so the x sits on their title line, not the glass's top.
    @Test func aRememberedTallerCardGivesItsRoomBackAndKeepsTheXOnTheWords() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = [SidebarUpdatedCardHost.rememberedHeightKey, SidebarUpdatedCardHost.rememberedHeightsKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        for key in keys { defaults.removeObject(forKey: key) }
        defaults.set([[216.0, 82.0 / Double(max(DesignSettings.shared.uiScale, 0.01))]], forKey: SidebarUpdatedCardHost.rememberedHeightsKey)

        let host = SidebarUpdatedCardHost(frame: NSRect(x: 0, y: 0, width: 216, height: 82))
        host.anchor = .bottom
        let surfaces = FakeSurfaces()
        host.configure(Self.card)
        host.surfaces = surfaces
        host.slotWidth = 216
        host.holdFirstFrame()
        let island = try #require(surfaces.islands.last)

        // The words are loading: one line (48), the hold keeps the remembered 82.
        island.report(height: 48, title: 17, settled: false)
        #expect(abs(host.height - 82) < 0.5)
        host.layout()
        let wordsTop = host.bounds.maxY - 48
        #expect(abs(host.closeButton.frame.midY - (wordsTop + 17)) < 0.01,
                "the x \(host.closeButton.frame) is not on the words' title line at \(wordsTop + 17)")

        // The words are final and still one line: the card is their height.
        island.report(height: 48, title: 17, settled: true)
        #expect(host.height == 48)
        host.setFrameSize(NSSize(width: 216, height: 48))
        host.layout()
        #expect(abs(host.closeButton.frame.midY - 17) < 0.01)
    }

    /// The page's report reads its title line and settled state; a report that only becomes settled lays the
    /// card out again (the host gives back a taller remembered height then).
    @Test func theReportCarriesTheTitleLineAndSettled() throws {
        let params = JSONValue.object(["height": .number(48), "title": .number(17), "settled": .bool(true)])
        let report = try #require(PageSurfaceReport(params: params))
        #expect(report == PageSurfaceReport(height: 48, title: 17, settled: true))
        #expect(PageSurfaceReport(params: .object(["title": .number(17)])) == nil, "a report without a height")
        var size = PageSurfaceSize()
        let laid5 = size.take(PageSurfaceReport(height: 48, title: 17), zoom: 1)
        #expect(laid5)
        #expect(!size.settled)
        let laid6 = size.take(PageSurfaceReport(height: 48, title: 17, settled: true), zoom: 1)
        #expect(laid6, "settling alone lays the card out")
        #expect(size.settled)
        let laid7 = size.take(PageSurfaceReport(height: 48, title: 17, settled: true), zoom: 1)
        #expect(!laid7)
    }
}
