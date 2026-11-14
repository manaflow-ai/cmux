// AgentCardRasterizer is iOS-only: these run in the iOS simulator test pass.
#if os(iOS)
import CmuxMobileModel
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileAgentChat
@testable import CmuxMobileWorkspaces

/// A memory warning gives back the grid's agent-card pictures that no card shows (Leo,
/// 2026-11-14: "I want us to also look at if we can decrease battery drain/ram on iOS app and
/// cc aziz too"). Before, the rasterizer kept up to `limit` (30) pictures of about 1.6 MB each
/// through a warning, which let go only the thumbnails held for the card being drawn.
@MainActor @Suite(.serialized) struct AgentCardRasterMemoryTests {
    final class Silent: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "codex", agentName: "Codex", cwd: "~", workspaceTitle: "w", macName: "m")
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) {}
    }

    static let page = CGSize(width: 402, height: 874)

    static func card(_ index: Int) -> (AgentCardFeed, AgentCardRasterKey) {
        var turn = AgentTurn(id: "t\(index)", prompt: "Card \(index)", promptAt: Date(timeIntervalSince1970: 0))
        turn.items = [.message(id: "m\(index)", markdown: "Reply \(index)")]
        turn.status = .completed
        let feed = AgentCardFeed(store: AgentChatStore(source: Silent()))
        let key = AgentCardRasterKey.current(feed, turns: [turn], colorScheme: .dark, page: page, visibleHeight: page.height,
                                             topInset: 70, bottomInset: 110, scale: 1)
        return (feed, key)
    }

    static func pictureBytes(_ feeds: [AgentCardFeed]) -> Int {
        feeds.reduce(0) { total, feed in
            guard let cg = feed.raster?.image.cgImage else { return total }
            return total + cg.bytesPerRow * cg.height
        }
    }

    /// Eight cards drawn, two of them on screen: a warning keeps those two pictures (the grid
    /// shows them as they are) and lets the other six go; a card built again asks for its
    /// picture again (`AgentTabCard`).
    @Test func aMemoryWarningDropsThePicturesNoCardShows() throws {
        let cards = (0..<8).map { Self.card($0) }
        for card in cards { try #require(card.1.isDrawable) }
        let rasterizer = AgentCardRasterizer()
        for card in cards { rasterizer.want(card.0, card.1) }
        rasterizer.setIdle(true)
        for _ in cards { rasterizer.frame() }
        rasterizer.setIdle(false)
        let feeds = cards.map(\.0)
        #expect(feeds.allSatisfy { $0.raster != nil }, "every card is drawn")
        rasterizer.setShown(feeds[0], true)
        rasterizer.setShown(feeds[1], true)
        rasterizer.setShown(feeds[2], true)
        rasterizer.setShown(feeds[2], false)
        let before = Self.pictureBytes(feeds)

        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        let after = Self.pictureBytes(feeds)
        print("card-pictures: \(feeds.count) pictures \(before) bytes before a memory warning, \(feeds.filter { $0.raster != nil }.count) pictures \(after) bytes after")
        #expect(feeds[0].raster != nil && feeds[1].raster != nil, "the cards on screen keep their pictures")
        #expect(feeds[2...].allSatisfy { $0.raster == nil }, "the pictures no card shows go")

        // A card that comes back asks for its picture and gets it.
        rasterizer.want(cards[5].0, cards[5].1)
        rasterizer.setIdle(true)
        rasterizer.frame()
        rasterizer.setIdle(false)
        #expect(cards[5].0.raster?.key == cards[5].1)
    }
}
#endif
