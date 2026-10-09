import AppKit
import Testing
@testable import MessagesLabSidebar

/// A pinned tile's unread dot sits on the tile's leading edge, outside the
/// newest-message bubble, as in Messages: a wide bubble never covers it.
@MainActor @Suite struct SidebarPinnedDotTests {
    static func summary(_ preview: String) -> ConversationSummary {
        ConversationSummary(id: "c", title: "Austin Wang", participants: [], avatar: .monogram("A"), preview: preview,
                            previewSender: nil, lastAt: Date(timeIntervalSince1970: 1_790_000_000), unreadCount: 1,
                            pinned: true, muted: false, typing: false, lastReaction: nil, version: 1)
    }

    @Test(arguments: [320, 260, 220, 400] as [CGFloat])
    func theDotStaysOutsideAWideBubble(width: CGFloat) throws {
        let m = SidebarMetrics(width: width)
        let c = Self.summary("Can you look at the layout diff before the nightly? It is long enough for two lines.")
        let bubble = try #require(SidebarDraw.tileBubble(c, metrics: m)).rect
        let dot = SidebarDraw.tileUnreadDot(m, bubble: bubble)
        let avatar = SidebarDraw.tileAvatar(m)
        #expect(!dot.intersects(bubble))
        #expect(dot.minX >= 0 && dot.maxX <= m.tileWidth && dot.minY >= 0 && dot.maxY <= m.tileHeight)
        // Leading edge: left of the avatar's centre, at the avatar's left side.
        #expect(dot.midX < avatar.minX + avatar.width * 0.25)
    }

    @Test func aShortBubbleKeepsTheDotOutsideToo() throws {
        let m = SidebarMetrics(width: 320)
        let bubble = try #require(SidebarDraw.tileBubble(Self.summary("ok"), metrics: m)).rect
        #expect(!SidebarDraw.tileUnreadDot(m, bubble: bubble).intersects(bubble))
    }
}
