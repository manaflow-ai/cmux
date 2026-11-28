import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// Leo, 2026-11-23: scrolling a long draft in the composer must scroll the draft, not swipe the
/// composer and keyboard down. `ChatDraftDragClaim` says which drags are the text's own.
@Suite struct ChatDraftDragClaimTests {
    @Test func aScrolledLongDraftOwnsTheDrag() {
        #expect(ChatDraftDragClaim.textOwnsDrag(contentHeight: 400, visibleHeight: 150, offsetFromTop: 120))
    }

    @Test func aLongDraftAtItsTopLeavesTheDragToTheHost() {
        #expect(!ChatDraftDragClaim.textOwnsDrag(contentHeight: 400, visibleHeight: 150, offsetFromTop: 0))
    }

    @Test func aDraftThatFitsLeavesTheDragToTheHost() {
        #expect(!ChatDraftDragClaim.textOwnsDrag(contentHeight: 120, visibleHeight: 150, offsetFromTop: 0))
    }
}
