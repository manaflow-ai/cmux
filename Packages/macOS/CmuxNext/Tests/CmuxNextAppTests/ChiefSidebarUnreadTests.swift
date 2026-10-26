import AppKit
import CmuxHomeCore
@testable import CmuxNextAgentLanes
@testable import CmuxNextApp
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// The Chief item's unread dot comes from the one source behind Home's own dot (#23933): the App's Home list,
/// through the item's real status observer, never a status set by hand.
@MainActor @Suite(.serialized)
struct ChiefSidebarUnreadTests {
    struct NoWorkspace: Error {}

    /// The App's services with Home listing the Chief's conversation: read unless `unread` messages wait, muted
    /// with `muted`, and not marked.
    static func services(unread: Int = 0, muted: Bool = false) -> AppServices {
        _ = NSApplication.shared // the services read NSApp
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.home.groupMuting.debugRows = [HomeUnreadIndicatorTests.row("chief", unread: unread, muted: muted)]
        services.home.groupMuting.setMarkedUnread(false, ConversationID("chief"))
        return services
    }

    /// The Chief item following a host whose unread is the App's (`SidebarSectionHandlers`), its conversation `chief`.
    static func follow(_ services: AppServices) -> ChiefSidebar {
        let chief = ChiefSidebar(lanes: AgentLaneStore())
        let home = services.home.groupMuting
        chief.follow(.init(conversation: { "chief" }, chiefHost: { nil }, tab: { _, _ in nil }, reveal: { _ in false },
                           openWorkspace: { _, _ in throw NoWorkspace() }, unread: { ChiefSidebar.isUnread("chief", in: home) }))
        return chief
    }

    /// Unread messages on a muted Chief conversation: Home shows no dot, so neither does the Chief item.
    /// Unmuted, the same messages dot both.
    @Test(arguments: [false, true])
    func theChiefItemDotsExactlyWhenHomeDoes(muted: Bool) async throws {
        let services = Self.services(unread: 2, muted: muted)
        try #require(services.home.unreadConversations.isEmpty == muted, "Home's own dot is not what this case expects")
        let chief = Self.follow(services)
        await RapidWorkspaceCreateTests.wait(within: muted ? .milliseconds(300) : .seconds(5)) { chief.status.unread }
        #expect(chief.status.unread == !muted, muted ? "a muted Chief conversation dots the item though Home shows none"
                                                     : "an unread Chief conversation shows no dot on the item")
    }

    /// Mark as Unread on the read Chief conversation: Home dots it, so the Chief item's status shows it unread;
    /// Mark as Read takes it back.
    @Test func markAsUnreadInHomeShowsOnTheChiefItem() async throws {
        let services = Self.services()
        let home = services.home.groupMuting
        let chief = Self.follow(services)
        await RapidWorkspaceCreateTests.wait(within: .milliseconds(300)) { chief.status.unread }
        #expect(!chief.status.unread, "a read Chief conversation shows unread")

        home.setMarkedUnread(true, ConversationID("chief"))
        try #require(home.unreadConversations == [ConversationID("chief")], "Home does not dot the marked conversation")
        await RapidWorkspaceCreateTests.wait(within: .seconds(5)) { chief.status.unread }
        #expect(chief.status.unread, "Mark as Unread in Home does not show on the Chief item")

        home.setMarkedUnread(false, ConversationID("chief"))
        await RapidWorkspaceCreateTests.wait(within: .seconds(5)) { !chief.status.unread }
        #expect(!chief.status.unread, "Mark as Read in Home leaves the Chief item unread")
    }
}
