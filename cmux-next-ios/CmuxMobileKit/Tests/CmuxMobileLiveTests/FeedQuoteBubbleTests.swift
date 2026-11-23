#if os(iOS)
@testable import CmuxMobileFeed
import Foundation
import Testing
import UIKit

/// A quote bubble's outline is a boolean path operation (~1 ms on every quoted row's apply,
/// profile 8a637e86): one of a size already drawn is not computed again.
@MainActor
@Suite(.serialized) struct FeedQuoteBubbleTests {
    @Test func aQuoteBubbleOfAKnownSizeIsNotComputedAgain() {
        let rect = CGRect(x: 0, y: 0, width: 280, height: 64)
        _ = FeedQuoteView.bubblePath(rect, outgoing: true)
        let made = FeedQuoteView.bubblesMade
        for _ in 0..<20 {
            _ = FeedQuoteView.bubblePath(rect, outgoing: true)
        }
        #expect(FeedQuoteView.bubblesMade == made)
        _ = FeedQuoteView.bubblePath(rect, outgoing: false)
        #expect(FeedQuoteView.bubblesMade == made + 1, "another side is another bubble")
    }
}
#endif
