import Foundation
import Testing
@testable import CmuxMobileFeed

/// Full verify D10: short inline rows skip the web view.
@Suite struct FeedPlainTextTests {
    @Test func shortInlineTextIsNative() {
        #expect(FeedPlainText("Finished its turn in the terminal. Open it to see the result.").isInline)
        #expect(FeedPlainText("**Needs approval:** run `ls -la` in **web**").isInline)
        #expect(FeedPlainText("**Needs approval:** run `ls`").attributed != nil)
    }

    @Test func blocksKeepTheWebRenderer() {
        #expect(!FeedPlainText("Here:\n```swift\nlet a = 1\n```").isInline)
        #expect(!FeedPlainText("- one\n- two").isInline)
        #expect(!FeedPlainText("# Title").isInline)
        #expect(!FeedPlainText("| a | b |\n|---|---|").isInline)
        #expect(!FeedPlainText("1. first").isInline)
        #expect(!FeedPlainText(String(repeating: "word ", count: 80)).isInline)
        #expect(!FeedPlainText("a\nb\nc\nd\ne").isInline)
        #expect(!FeedPlainText("Title\n===").isInline)
        #expect(!FeedPlainText("above\n---\nbelow").isInline)
    }

    /// A row built again (scrolled back in, a live change) reuses its body's answer.
    @MainActor @Test func inlineTextIsParsedOncePerBody() {
        let cache = FeedInlineTextCache(limit: 8)
        let short = "**Needs approval:** run `ls`"
        #expect(cache.inlineText(short) != nil)
        #expect(cache.inlineText(short) != nil)
        #expect(cache.inlineText("# Title") == nil)
        #expect(cache.inlineText("# Title") == nil)
        #expect(cache.misses == 2)
    }
}
