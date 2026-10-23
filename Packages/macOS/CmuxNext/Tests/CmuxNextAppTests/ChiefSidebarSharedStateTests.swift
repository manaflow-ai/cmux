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
    /// The sidebar document: This Mac's list holds the Work group, and the Chief sits in that group.
    static let document = Data("""
    {"revision": "1",
     "sections": [{"id": "sec_m_s1", "kind": {"type": "machine", "session_id": "s1"}}],
     "items": [
       {"id": "g_work", "section": "sec_m_s1", "order": "a", "body": {"type": "group", "name": "Work"}},
       {"id": "itm_chief", "section": "sec_m_s1", "parent": "g_work", "order": "a", "body": {"type": "builtin", "id": "chief"}}
     ]}
    """.utf8)

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

    static func loadedDocument() async throws -> SidebarDocStore {
        let store = SidebarDocStore(remote: SidebarGroupDragRailTests.Remote(document: document))
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
        defer { followB.cancel() }
        await RapidWorkspaceCreateTests.wait(within: .seconds(1)) { !chief.isPlaced }
        #expect(chief.isPlaced, "window B's feed took the Chief off though the document still places it")
    }

    /// Only window B is open, and its rows draw no Chief: the document places one, so it counts as placed.
    @Test func theDocumentAloneDecidesWhereNoWindowDrawsTheChief() async throws {
        let store = try await Self.loadedDocument()
        let chief = ChiefSidebar(lanes: AgentLaneStore())
        let follow = Self.window(listsChief: false).followTopItems(chief: chief, document: { store })
        defer { follow.cancel() }
        await RapidWorkspaceCreateTests.wait(within: .seconds(5)) { chief.isPlaced }
        #expect(chief.isPlaced, "the Chief the document places counts as not placed")
    }

    /// Home's list: the Chief's conversation, read.
    static func home() -> HomeSidebarSource {
        let suite = "cmux.tests.chiefSidebarUnread.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let rows = [HomeUnreadIndicatorTests.row("chief")]
        return HomeSidebarSource(store: HomePinStore(defaults: defaults), account: { "acct" }, rows: { rows },
                                 me: { HomeUnreadIndicatorTests.me }, contacts: { [] })
    }

    /// Mark as Unread on the read Chief conversation: Home dots it, so the Chief item's status (the App's
    /// binding, followed by the item's own observer) shows it unread; Mark as Read takes it back.
    @Test func markAsUnreadInHomeShowsOnTheChiefItem() async throws {
        let home = Self.home()
        let chief = ChiefSidebar(lanes: AgentLaneStore())
        chief.follow(ChiefSidebar.Host(conversation: { "chief" }, chiefHost: { nil }, tab: { _, _ in nil }, reveal: { _ in false },
                                       openWorkspace: { _, _ in throw CancellationError() },
                                       unread: { ChiefSidebar.Host.unread(chief: "chief", in: home) }))
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
