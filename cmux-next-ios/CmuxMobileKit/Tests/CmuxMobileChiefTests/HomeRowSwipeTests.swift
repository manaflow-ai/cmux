#if os(iOS)
import Testing
@testable import CmuxMobileChief

/// User request 2026-11-03: Home's (Chief's) rows get swipe actions the way
/// Workspaces' rows do: trailing only (the rightward swipe stays the team
/// drawer's), the row menu's list-state actions, the outermost first.
@Suite struct HomeRowSwipeTests {
    @Test func anUnreadUnpinnedRowOffersReadThenPin() {
        #expect(HomeRowSwipe(isPinned: false, isUnread: true).actions == [.markRead, .pin])
    }

    @Test func aReadPinnedRowOffersUnreadThenUnpin() {
        #expect(HomeRowSwipe(isPinned: true, isUnread: false).actions == [.markUnread, .unpin])
    }

    @Test func everyRowHasExactlyOneReadActionAndOnePinAction() {
        for pinned in [false, true] {
            for unread in [false, true] {
                let actions = HomeRowSwipe(isPinned: pinned, isUnread: unread).actions
                #expect(actions.count == 2)
                #expect(actions.filter { $0 == .markRead || $0 == .markUnread }.count == 1)
                #expect(actions.filter { $0 == .pin || $0 == .unpin }.count == 1)
            }
        }
    }
}
#endif
