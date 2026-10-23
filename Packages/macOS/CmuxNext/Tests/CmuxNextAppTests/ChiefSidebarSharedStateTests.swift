import AppKit
import CmuxNextAgentActivity
import CmuxHomeCore
@testable import CmuxNextAgentLanes
@testable import CmuxNextApp
@testable import CmuxNextHomeEngine
@testable import CmuxNextSidebar
import Foundation
import Testing

/// The Chief item's state every window shares (#23933 review, Codex): whether it is placed, and whether its
/// conversation is unread. Each comes from the one source behind it, through the App's real observers, not
/// from one window's rows or a status set by hand.
@MainActor @Suite(.serialized)
struct ChiefSidebarSharedStateTests {
    /// The sidebar document: This Mac's list holds the Work group, and (with `chief`) the Chief sits in that group.
    static func document(chief: Bool = true) -> Data {
        let item = #"{"id": "itm_chief", "section": "sec_m_s1", "parent": "g_work", "order": "a", "body": {"type": "builtin", "id": "chief"}}"#
        return Data("""
        {"revision": "1",
         "sections": [{"id": "sec_m_s1", "kind": {"type": "machine", "session_id": "s1"}}],
         "items": [
           {"id": "g_work", "section": "sec_m_s1", "order": "a", "body": {"type": "group", "name": "Work"}}\(chief ? ", " + item : "")
         ]}
        """.utf8)
    }

    /// A window's sidebar: with `listsChief` its rows hold the Work group's Chief; without, its workspace
    /// membership leaves that group out, so it draws no Chief at all.
    static func window(listsChief: Bool) -> SidebarModel {
        let chief = SidebarListItem(id: "itm_chief", ref: .builtIn(.chief), title: SidebarBuiltIn.chief.title)
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [CmuxNextSidebar.SidebarSection(kind: .machine(machine), nodes: listsChief ? [.item(chief)] : [])],
                                 activeWorkspaceID: nil)
        model.layout = SidebarLayoutDocument(sections: [])
        return model
    }

    static func loadedDocument(chief: Bool = true) async throws -> SidebarDocStore {
        let store = SidebarDocStore(remote: SidebarGroupDragRailTests.Remote(document: document(chief: chief)))
        store.refresh()
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { store.isActive }
        try #require(store.isActive, "the store did not load the document")
        return store
    }

    /// Window A shows the Chief in its group; window B's membership leaves the group out. B's feed must not
    /// take the Chief off: the App Store card would offer Get, and Home's drag would add a second Chief.
    @Test func aWindowThatDrawsNoChiefStillCountsTheDocumentsChiefPlaced() async throws {
        let store = try await Self.loadedDocument()
        let chief = ChiefSidebar(lanes: AgentLaneStore())
        let a = Self.window(listsChief: true), b = Self.window(listsChief: false)
        let followA = a.followTopItems(chief: chief, document: { store })
        defer { followA.cancel() }
        await RapidWorkspaceCreateTests.wait(within: .seconds(5)) { chief.isPlaced }
        try #require(chief.isPlaced, "window A, which lists the Chief, does not count it placed")

        let followB = b.followTopItems(chief: chief, document: { store })
        defer { followB.cancel(); withExtendedLifetime((a, b)) {} } // the feed holds its window weakly
        await RapidWorkspaceCreateTests.wait(within: .seconds(1)) { !chief.isPlaced }
        #expect(chief.isPlaced, "window B's feed took the Chief off though the document still places it")
    }

    /// Only window B is open, and its rows draw no Chief: the document places one, so it counts as placed.
    @Test func theDocumentAloneDecidesWhereNoWindowDrawsTheChief() async throws {
        let store = try await Self.loadedDocument()
        let chief = ChiefSidebar(lanes: AgentLaneStore())
        let window = Self.window(listsChief: false)
        let follow = window.followTopItems(chief: chief, document: { store })
        defer { follow.cancel(); withExtendedLifetime(window) {} } // the feed holds its window weakly
        await RapidWorkspaceCreateTests.wait(within: .seconds(5)) { chief.isPlaced }
        #expect(chief.isPlaced, "the Chief the document places counts as not placed")
    }

    /// A drag in, then a drag out, before the daemon answers either (#23933 review): the Chief's placement is the
    /// sidebar as it draws (the document with its pending changes), not the confirmed document the daemon has not
    /// changed yet. Else the App Store card offers the wrong action and a quick drag in adds a second Chief.
    @Test func placementFollowsAChangeBeforeTheDaemonAnswers() async throws {
        let store = try await Self.loadedDocument(chief: false)
        let chief = ChiefSidebar(lanes: AgentLaneStore())
        let window = Self.window(listsChief: false)
        let follow = window.followTopItems(chief: chief, document: { store })
        defer { follow.cancel(); withExtendedLifetime(window) {} } // the feed holds its window weakly
        await RapidWorkspaceCreateTests.wait(within: .milliseconds(300)) { chief.isPlaced }
        try #require(!chief.isPlaced, "a document with no Chief counts one placed")

        // The test daemon never answers: no batch confirms either change.
        try store.sendChecked(ops: [["op": "item.add", "item": ["id": "itm_chief", "body": ["type": "builtin", "id": "chief"]],
                                     "to": ["section": "sec_m_s1"]]], title: "Add", undoable: false)
        #expect(store.placesItem(with: .builtIn(.chief)), "a Chief added and not yet confirmed counts as not placed")
        await RapidWorkspaceCreateTests.wait(within: .seconds(5)) { chief.isPlaced }
        #expect(chief.isPlaced, "the feed missed the Chief added before the daemon answered")

        try store.sendChecked(ops: [["op": "item.remove", "id": "itm_chief"]], title: "Remove", undoable: false)
        #expect(!store.placesItem(with: .builtIn(.chief)), "a Chief removed and not yet confirmed still counts as placed")
        await RapidWorkspaceCreateTests.wait(within: .seconds(5)) { !chief.isPlaced }
        #expect(!chief.isPlaced, "the feed kept the Chief removed before the daemon answered")
    }

    /// The App's services with Home listing the Chief's conversation: read unless `unread` messages wait, muted
    /// with `muted`, and not marked.
    static func services(unread: Int = 0, muted: Bool = false) -> AppServices {
        _ = NSApplication.shared // the services read NSApp
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.home.groupMuting.debugRows = [HomeUnreadIndicatorTests.row("chief", unread: unread, muted: muted)]
        services.home.groupMuting.setMarkedUnread(false, ConversationID("chief"))
        return services
    }

    /// The Chief item following the App's own host (`ChiefSidebar.Host.app`), its conversation the one listed.
    static func follow(_ services: AppServices) -> ChiefSidebar {
        let chief = ChiefSidebar(lanes: AgentLaneStore())
        chief.follow(.app(services, conversation: { "chief" }))
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

    /// Mark as Unread on the read Chief conversation: Home dots it, so the Chief item's status (the App's
    /// binding, followed by the item's own observer) shows it unread; Mark as Read takes it back.
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
