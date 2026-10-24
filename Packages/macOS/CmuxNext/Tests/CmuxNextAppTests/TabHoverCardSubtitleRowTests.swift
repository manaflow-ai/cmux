import AppKit
@testable import CmuxNextTabs
import Testing

/// A tab's hover card with nothing under its title (an agent chat) ends under the title, rather
/// than keeping an empty line where a subtitle would go. A capture of the Agent tab's card
/// showed that blank line.
@MainActor
struct TabHoverCardSubtitleRowTests {
    private func height(subtitle: String?) -> CGFloat {
        let card = TabHoverCardView(iconCaches: TabIconCaches())
        card.configure(.tab(TabItem(id: TabID("t"), title: "Agent", subtitle: subtitle)))
        card.setThumbnailVisible(false)
        card.layoutSubtreeIfNeeded()
        return card.fittingSize.height
    }

    @Test func aCardWithoutASubtitleKeepsNoLineForIt() {
        let without = height(subtitle: nil), with = height(subtitle: "~/Projects/cmux")
        // A caption line is taller than 10 pt; the subtitle's line is all that differs.
        #expect(with - without >= 10, "with a subtitle \(with) pt, without \(without) pt")
    }
}
