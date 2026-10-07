import CoreGraphics
import Testing
@testable import CmuxNextSidebar

/// R114 card stack: one front card, up to two peeking behind it, every card
/// in a column on hover, announcements only while the sidebar is revealed.
@Suite struct SidebarCardStackLayoutTests {
    private func card(_ id: String, always: Bool = true) -> SidebarCard {
        SidebarCard(id: id, title: id, alwaysVisible: always)
    }

    @Test func noCardsTakeNoRoom() {
        let layout = SidebarCardStackLayout.layout([], revealed: true, expanded: true, width: 200, cardHeight: 48)
        #expect(layout.height == 0)
        #expect(layout.placements.isEmpty)
    }

    @Test func collapsedShowsTheFrontCardAndUpToTwoPeeks() {
        let cards = ["a", "b", "c", "d"].map { card($0) }
        let layout = SidebarCardStackLayout.layout(cards, revealed: true, expanded: false, width: 200, cardHeight: 48)
        #expect(layout.placements.map(\.id) == ["a", "b", "c"])
        #expect(layout.placements[0].frame == CGRect(x: 0, y: 0, width: 200, height: 48))
        #expect(!layout.placements[0].isPeek)
        #expect(layout.placements[1].isPeek && layout.placements[2].isPeek)
        #expect(layout.placements[1].frame == CGRect(x: 6, y: 4, width: 188, height: 48))
        #expect(layout.placements[2].frame == CGRect(x: 12, y: 8, width: 176, height: 48))
        #expect(layout.height == 56)
    }

    @Test func expandedShowsEveryCardInAColumn() {
        let cards = ["a", "b", "c"].map { card($0) }
        let layout = SidebarCardStackLayout.layout(cards, revealed: true, expanded: true, width: 200, cardHeight: 48)
        #expect(layout.placements.map(\.frame) == [
            CGRect(x: 0, y: 0, width: 200, height: 48),
            CGRect(x: 0, y: 54, width: 200, height: 48),
            CGRect(x: 0, y: 108, width: 200, height: 48),
        ])
        #expect(layout.placements.allSatisfy { !$0.isPeek })
        #expect(layout.height == 156)
    }

    @Test func announcementsShowOnlyWhileRevealed() {
        let cards = [card("update"), card("news", always: false)]
        let hidden = SidebarCardStackLayout.layout(cards, revealed: false, expanded: false, width: 200, cardHeight: 48)
        #expect(hidden.placements.map(\.id) == ["update"])
        #expect(hidden.height == 48)
        let shown = SidebarCardStackLayout.layout(cards, revealed: true, expanded: false, width: 200, cardHeight: 48)
        #expect(shown.placements.map(\.id) == ["update", "news"])
        let onlyNews = SidebarCardStackLayout.layout([card("news", always: false)], revealed: false, expanded: false, width: 200, cardHeight: 48)
        #expect(onlyNews.height == 0)
    }
}
