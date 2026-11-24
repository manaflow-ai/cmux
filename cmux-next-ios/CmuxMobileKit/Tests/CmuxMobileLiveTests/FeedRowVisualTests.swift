#if os(iOS)
@testable import CmuxMobileFeed
import CmuxMobileDesign
import CmuxMobileMarkdown
import CmuxMobileModel
import Testing
import UIKit

/// A Feed card is a glance, as a Threads post (manaflow-ai/cmux#51332, "these are still taking up
/// way too much space… ONLY signal stuff"): a small avatar, a one-line header, the reply's first
/// lines in text two sizes under the reader's, the pull request on one line, icon-only actions.
/// The person's own prompt and a "Finished" headline are not drawn.
@MainActor
@Suite struct FeedRowVisualTests {
    static let width = 393

    static func item(_ markdown: String, kind: FeedItem.Kind = .response, quote: FeedItem.Quote? = nil) -> FeedItem {
        FeedItem(id: "q", kind: kind, workspaceID: "w1", tabID: "t", agentName: "Claude", harness: "claude",
                 workspaceTitle: "cmux", markdown: markdown, quote: quote, createdAt: Date(timeIntervalSince1970: 1_000_000))
    }

    static func layout(_ item: FeedItem, category: UIContentSizeCategory = .large) -> FeedRowLayout {
        let key = FeedRowKey(item: item, state: FeedRowState(), width: width, textSize: category.rawValue)
        return FeedRowLayout.make(key, styles: NativeTextStyles(category: category), scale: 3)
    }

    @Test func aFinishedReplyIsAFewLinesTallWithoutThePromptOrAHeadline() {
        let card = Self.layout(Self.item("Implemented both tools: 44 tests passed.",
                                         quote: .init("Write a Brainfuck-to-C compiler and an optimizing interpreter in Python")))
        #expect(card.quote == nil, "the person's own prompt is not signal")
        #expect(card.headline.frame == .zero, "\"Finished\" says nothing the reply does not")
        #expect(card.avatar.width == 32)
        // Header, one line of body, the icon row: well under the old ~170 pt card.
        #expect(card.height < 100, "a one-line reply is \(card.height) pt tall")
    }

    @Test func aLongReplyShowsThreeLinesThenShowMore() {
        let long = (1...30).map { "Line \($0) of a long reply that wraps across the column." }.joined(separator: " ")
        let card = Self.layout(Self.item(long))
        let line = ceil(FeedRowLayout.compact(NativeTextStyles(category: .large)).font(.body).lineHeight)
        #expect(card.body.overflowing)
        #expect(card.body.frame.height <= line * 3 + 2)
        #expect(card.body.showMore != nil)
    }

    @Test func textIsTwoSizesUnderTheReaders() {
        #expect(FeedRowLayout.compact(NativeTextStyles(category: .large)).category == .small)
        #expect(FeedRowLayout.compact(NativeTextStyles(category: .extraSmall)).category == .extraSmall)
        #expect(FeedRowLayout.compact(NativeTextStyles(category: .accessibilityLarge)).category == .extraExtraExtraLarge)
    }

    @Test func aPullRequestIsOneCompactRowWithItsState() throws {
        var item = Self.item("Opened the PR.")
        item.pullRequest = PullRequestSummary(url: try #require(URL(string: "https://github.com/o/r/pull/9")), number: 9,
                                              title: "Feed cards", state: .open, checks: .passing, mergeable: true)
        item.devBuild = "feed-threads"
        let card = Self.layout(item)
        let pull = try #require(card.pull)
        #expect(pull.state.string.contains("Ready to merge") && pull.state.string.contains("feed-threads"))
        #expect(pull.build == nil, "the dev build shares the state's line")
        #expect(pull.frame.height < 50, "the PR row is \(pull.frame.height) pt")
        #expect(card.footerHasPull && card.footerHasMerge)
    }

    @Test func aFailureKeepsItsHeadline() {
        let card = Self.layout(Self.item("The build broke.", kind: .failed))
        #expect(card.headline.text.string == "Failed")
        #expect(card.headline.dot != nil)
    }
}
#endif
