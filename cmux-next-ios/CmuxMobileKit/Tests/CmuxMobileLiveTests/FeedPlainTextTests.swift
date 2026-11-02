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

    @Test(arguments: [
        #"The backoff follows $d_n = \min(d_{\max}, d_0 2^n)$ with jitter. The fifth retry waits about $4\,\text{s}$."#,
        #"The answer is \(x^2\)."#,
        "$$\nx^2\n$$",
        #"\[x^2\]"#,
    ])
    func mathKeepsTheSharedRenderer(markdown: String) {
        #expect(!FeedPlainText(markdown).isInline)
    }

    @Test func pricesAndEscapedDollarsStayNative() {
        #expect(FeedPlainText("It costs $5 and $6.").isInline)
        #expect(FeedPlainText(#"The price is \$5."#).isInline)
        #expect(FeedPlainText("Run `echo $$`.").isInline)
    }
}
