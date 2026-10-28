import CmuxNextLayout
import Testing

/// Lucas 2026-10-26: Cmd-I opened a docked chat once per workspace; after that chat closed, Cmd-I
/// did nothing. The chat's provisional id stayed pending once the store dropped its alias, and
/// DockedAgentChat treats any pending chat as the one Cmd-I already opened.
@Suite struct PendingDockChatsTests {
    @Test func aChatThatDockedAfterItsAliasWentIsNotPending() {
        var pending = PendingDockChats()
        pending.opened("provisional-1")
        pending.created("provisional-1", as: "tab-1")
        // The store's tree no longer lists the provisional tab, so its alias is gone.
        pending.finished("tab-1", aliases: [:])
        #expect(pending.isEmpty)
    }

    @Test func aChatThatNeverCameIsNotPending() {
        var pending = PendingDockChats()
        pending.opened("provisional-1")
        pending.finished("provisional-1", aliases: [:])
        #expect(pending.isEmpty)
    }

    @Test func theStoresEchoBeforeItsReplyStillFinishesTheChat() {
        var pending = PendingDockChats()
        pending.opened("provisional-1")
        pending.finished("tab-1", aliases: ["provisional-1": "tab-1"])
        #expect(pending.isEmpty)
    }

    @Test func anotherChatOnItsWayStaysPending() {
        var pending = PendingDockChats()
        pending.opened("provisional-1")
        pending.opened("provisional-2")
        pending.created("provisional-1", as: "tab-1")
        pending.finished("tab-1", aliases: [:])
        #expect(!pending.isEmpty)
        #expect(pending.hidden(aliases: [:]) == ["provisional-2"])
    }

    @Test func theStripHidesEveryIdOfAChatOnItsWay() {
        var pending = PendingDockChats()
        pending.opened("provisional-1")
        #expect(pending.hidden(aliases: ["provisional-1": "tab-1"]) == ["provisional-1", "tab-1"])
        pending.created("provisional-1", as: "tab-1")
        #expect(pending.hidden(aliases: [:]) == ["provisional-1", "tab-1"])
    }
}
