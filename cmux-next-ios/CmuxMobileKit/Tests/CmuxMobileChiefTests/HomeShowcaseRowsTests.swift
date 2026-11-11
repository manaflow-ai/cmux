import Foundation
import Testing
@testable import CmuxMobileChief

/// `-cmux-mobile-demo home-showcase` (App Store screenshots): Home lists real-looking
/// conversations with no link, not the list rig's numbered placeholders.
@MainActor
@Suite struct HomeShowcaseRowsTests {
    @Test func showcaseRowsLookLikeAPersonsHome() throws {
        let feed = MacHomeFeed()
        feed.seedShowcaseRows(macID: "mac-studio")
        let rows = try #require(feed.rows)
        #expect(rows.count == 7)
        #expect(rows.filter(\.isPinned).count == 2)
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(rows.allSatisfy { !$0.name.isEmpty && !$0.preview.isEmpty && !$0.name.hasPrefix("Conversation ") })
        #expect(feed.macID == "mac-studio")
    }
}
