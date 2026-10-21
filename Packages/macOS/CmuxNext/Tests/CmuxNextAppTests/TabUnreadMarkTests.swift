@testable import CmuxNextApp
import Testing

/// Mark Tab Unread's rules (`TabUnreadMark`): what a toggle does, and which
/// viewed tabs clear their mark.
@MainActor
@Suite struct TabUnreadMarkTests {
    @Test func aTabThatShowsReadIsMarkedUnreadAndAnUnreadOneIsRead() {
        #expect(TabUnreadMark.step(showsUnread: false) == .markUnread, "any read tab can be marked, notification or not")
        #expect(TabUnreadMark.step(showsUnread: true) == .read)
    }

    @Test func onlyTabsThatComeIntoViewClearTheirMark() {
        #expect(TabUnreadMark.entered(["a", "b"], previous: []) == ["a", "b"], "the first pass views every tab")
        #expect(TabUnreadMark.entered(["a"], previous: ["a"]).isEmpty, "a tab marked while viewed keeps the mark")
        #expect(TabUnreadMark.entered(["b"], previous: ["a"]) == ["b"], "switching to a tab views it")
        #expect(TabUnreadMark.entered([], previous: ["a"]).isEmpty, "leaving view clears nothing")
    }
}
