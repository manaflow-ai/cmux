import CmuxHomeCore
@testable import CmuxNextApp
@testable import CmuxNextHome
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Home's unread shows outside Home too (Lawrence 2026-10-21: "we need to show unread indicator
/// in home too"): the conversations the Home list dots (unread messages or Mark as Unread, never a
/// muted one) are the one source; the sidebar's Home item dots while any is, whether Home is the
/// built-in or the first-party app item.
@MainActor
struct HomeUnreadIndicatorTests {
    static let me = ParticipantID("me")

    static func row(_ id: String, unread: Int = 0, muted: Bool = false) -> InboxRow {
        let at = Date(timeIntervalSince1970: 1_000)
        let mine = Participant(id: me, kind: .human, displayName: "Me")
        let peer = Participant(id: ParticipantID("peer-\(id)"), kind: .human, displayName: "Peer \(id)")
        let summary = ConversationSummary(id: ConversationID(id), participants: [mine, peer], createdAt: at, updatedAt: at)
        var mirror = HomeMirror()
        _ = mirror.apply(inbox: InboxSnapshot(me: mine, conversations: [summary], rev: 1))
        var row = mirror.inboxRows(log: IntentLog())[0]
        row.unread = unread
        row.summary.muted = muted
        return row
    }

    @Test func theUnreadConversationsAreTheListsDotsWithoutMutedOnes() {
        let rows = [Self.row("read"), Self.row("new", unread: 2), Self.row("marked"), Self.row("muted", unread: 4, muted: true)]
        let model = HomeSidebarModel(ordered: rows, pinned: [], me: Self.me, unreadMarks: [ConversationID("marked")])
        #expect(Set(model.unreadConversations) == [ConversationID("new"), ConversationID("marked")])
        // Reading it clears the dot; the indicator follows.
        let read = HomeSidebarModel(ordered: [Self.row("read"), Self.row("new"), Self.row("marked")], pinned: [], me: Self.me)
        #expect(read.unreadConversations.isEmpty)
    }

    @Test func pinnedTilesCountToo() {
        let rows = [Self.row("chief", unread: 1), Self.row("dm")]
        let model = HomeSidebarModel(ordered: rows, pinned: [ConversationID("chief")], me: Self.me)
        #expect(model.unreadConversations == [ConversationID("chief")])
    }

    @Test(arguments: [LayoutItemRef.builtIn(.home), .app("cmux/home")])
    func theSidebarsHomeItemDotsHomesUnread(_ ref: LayoutItemRef) {
        let item = LayoutItem(id: LayoutItemID("itm_home"), ref: ref)
        let layout = SidebarLayoutDocument(sections: [LayoutSection(id: LayoutSectionID("sec_top"), region: .top, items: [item])])
        let unread = SidebarBridge.itemInfo(for: layout, registered: { _ in true }, homeUnread: 3)[item.id]
        // A dot, not a count (Lawrence 2026-10-23: "home unread indicator should just be blue dot instead").
        #expect(unread?.unreadDot == true && unread?.badge == nil)
        let read = SidebarBridge.itemInfo(for: layout, registered: { _ in true }, homeUnread: 0)[item.id]
        #expect(read?.badge == nil && read?.unreadDot == false)
        // Home's unread is Home's alone: the Notifications count does not take it.
        let bell = LayoutItem(id: LayoutItemID("itm_bell"), ref: .builtIn(.notifications))
        let both = SidebarLayoutDocument(sections: [LayoutSection(id: LayoutSectionID("sec_top"), region: .top, items: [item, bell])])
        #expect(SidebarBridge.itemInfo(for: both, registered: { _ in true }, homeUnread: 3)[bell.id]?.badge == nil)
    }

    @Test func aHomeTabIsTheHomePageTheDockedHomeOrTheHomeApp() {
        #expect(HomeService.isHomeTab(page: "home-tab", app: nil))
        #expect(HomeService.isHomeTab(page: "home-dock", app: nil))
        #expect(HomeService.isHomeTab(page: nil, app: "cmux/home"))
        #expect(!HomeService.isHomeTab(page: "settings", app: nil))
        #expect(!HomeService.isHomeTab(page: nil, app: "cmux/app-store"))
        #expect(!HomeService.isHomeTab(page: nil, app: nil))
    }
}
