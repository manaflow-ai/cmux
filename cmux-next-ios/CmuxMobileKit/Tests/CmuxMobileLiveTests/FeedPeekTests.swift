import CoreGraphics
import Testing
@testable import CmuxMobileFeed

/// Long-press a Feed row to peek at its chat: what the preview shows and how big it is.
@Suite struct FeedPeekTests {
    @Test func aLoadedChatShowsItsTurns() {
        #expect(FeedPeek.content(opensTerminal: false, hasLink: false, loadedTurns: 3) == .chat)
        #expect(FeedPeek.content(opensTerminal: false, hasLink: false, loadedTurns: 1) == .chat)
    }

    /// A chat the phone does not hold shows the event's own text: never a spinner or an empty card.
    @Test func anUnloadedChatShowsTheEvent() {
        #expect(FeedPeek.content(opensTerminal: false, hasLink: false, loadedTurns: 0) == .event)
    }

    /// A terminal agent's event and a Mac Feed request open a terminal or a page, not a chat.
    @Test func terminalAndLinkEventsShowTheEvent() {
        #expect(FeedPeek.content(opensTerminal: true, hasLink: false, loadedTurns: 5) == .event)
        #expect(FeedPeek.content(opensTerminal: false, hasLink: true, loadedTurns: 5) == .event)
    }

    @Test func aChatPreviewIsAboutTwoThirdsOfTheScreen() {
        // iPhone 17 Pro Max: two thirds fits above the menu.
        let big = FeedPeek.size(container: CGSize(width: 440, height: 956))
        #expect(big == CGSize(width: 408, height: 616))
        // iPhone 17 Pro: the menu's room caps it a little under two thirds.
        let pro = FeedPeek.size(container: CGSize(width: 402, height: 874))
        #expect(pro == CGSize(width: 370, height: 534))
        // A short screen (iPhone SE) keeps room for the menu.
        let small = FeedPeek.size(container: CGSize(width: 375, height: 667))
        #expect(small == CGSize(width: 343, height: 327))
    }

    /// An unfolded phone's wide window gets a readable column, not an edge-to-edge card.
    @Test func aWideWindowCapsThePreviewWidth() {
        #expect(FeedPeek.size(container: CGSize(width: 800, height: 820)).width == FeedPeek.maxWidth)
    }

    @Test func anEventPreviewIsAsTallAsItsText() {
        let container = CGSize(width: 402, height: 874)
        #expect(FeedPeek.size(container: container, fitting: 201.4).height == 202)
        // Never taller than a chat's preview, never a sliver.
        #expect(FeedPeek.size(container: container, fitting: 4000).height == 534)
        #expect(FeedPeek.size(container: container, fitting: 20).height == FeedPeek.minHeight)
    }
}
