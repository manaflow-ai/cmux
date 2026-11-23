import CoreGraphics
import Testing
@testable import CmuxMobileDesign

/// Leo, 2026-11-23: scrolling a long draft in the composer must scroll the draft, not
/// swipe the composer and keyboard down. `ComposerTextDragClaim` says which drags are
/// the text's own; the hosts' swipe-down-to-dismiss steps aside for those.
@Suite struct ComposerTextDragClaimTests {
    @Test func aScrolledLongDraftOwnsTheDrag() {
        #expect(ComposerTextDragClaim.textOwnsDrag(contentHeight: 400, visibleHeight: 150, offsetFromTop: 120))
    }

    @Test func aLongDraftAtItsTopLeavesTheDragToTheHost() {
        // The swipe-down-to-collapse case: nothing above to scroll to.
        #expect(!ComposerTextDragClaim.textOwnsDrag(contentHeight: 400, visibleHeight: 150, offsetFromTop: 0))
    }

    @Test func aDraftThatFitsLeavesTheDragToTheHost() {
        #expect(!ComposerTextDragClaim.textOwnsDrag(contentHeight: 44, visibleHeight: 44, offsetFromTop: 0))
        #expect(!ComposerTextDragClaim.textOwnsDrag(contentHeight: 44.3, visibleHeight: 44, offsetFromTop: 0))
    }
}

#if os(iOS)
import UIKit

@MainActor @Suite struct ComposerReturnTextViewDragTests {
    private func longDraft() -> ComposerReturnTextView {
        let view = ComposerReturnTextView(policy: .init(style: .chat, maxLines: 6))
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 120)
        view.text = (1...40).map { "line \($0)" }.joined(separator: "\n")
        view.layoutIfNeeded()
        return view
    }

    @Test func theFieldClaimsTheDragOnlyWhenScrolledAwayFromItsTop() {
        let view = longDraft()
        #expect(view.textOverflows)
        view.contentOffset.y = -view.adjustedContentInset.top
        #expect(!view.textOwnsDrag)
        view.contentOffset.y = 200
        #expect(view.textOwnsDrag)
    }
}
#endif
