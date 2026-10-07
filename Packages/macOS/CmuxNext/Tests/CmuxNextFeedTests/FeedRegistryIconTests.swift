import CmuxNextIcons
import Testing
@testable import CmuxNextFeed

/// Feed items show their kind with the cmux icon registry (one semantic name
/// per meaning) at the row size of the text beside them.
@MainActor @Suite struct FeedRegistryIconTests {
    @Test func kindsNameTheirRegistryIcon() {
        #expect(FeedGlyph.icon(for: FeedModelTests.openApprove) == .terminal)
        let integration = FeedItem(id: "fi_i", title: "PR", poster: FeedPoster(kind: .integration, label: "GitHub"), createdAt: feedTestNow)
        #expect(FeedGlyph.icon(for: integration) == .integration)
        let notice = FeedItem(id: "fi_n", title: "Done", poster: FeedPoster(kind: .system, label: "status run"), createdAt: feedTestNow)
        #expect(FeedGlyph.icon(for: notice) == .notification)
        let server = FeedItem(id: "fi_s", title: "Up", poster: FeedPoster(kind: .server, label: "build"), createdAt: feedTestNow)
        #expect(FeedGlyph.icon(for: server) == .machineRemote)
    }

    /// A glyph's box is the row size of its text, so the pack's ink matches
    /// the SF Symbol it replaced instead of shrinking to two thirds of it.
    @Test func aGlyphIsTheRowSizeOfItsText() {
        #expect(FeedGlyph.side(forTextSize: 11) == .iconRowSize(forLabelPointSize: 11))
        #expect(FeedGlyph.side(forTextSize: 15) == .iconRowSize(forLabelPointSize: 15))
    }
}
