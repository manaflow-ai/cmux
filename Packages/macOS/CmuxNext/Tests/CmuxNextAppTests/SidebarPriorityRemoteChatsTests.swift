import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
@testable import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import Testing

/// The Priority view ranks every agent chat, not only this Mac's acpmux and its peers: a chat
/// on a Cloud VM, an SSH machine or a server shows from that machine's daemon tree (its agent
/// chat tab, and the notice that machine's daemon posts on it when the chat needs the person,
/// finishes or fails), ranked with the rest. Each row names its machine the way the sidebar
/// does (`MachineRegistry.machineName`); this Mac's rows carry no tag unless
/// `sidebar.showLocalMachine` asks for this Mac's name.
@MainActor
struct SidebarPriorityRemoteChatsTests {
    static let now = Date()

    static func lane(_ id: String, _ state: AgentActivityLane.State, ago minutes: Double, unread: Bool = false,
                     peer: String? = nil) -> AgentActivityLane {
        AgentActivityLane(id: id, name: id, title: id, peer: peer, parent: nil, state: state,
                          since: now.addingTimeInterval(-minutes * 60), error: nil, unread: unread, project: "cmux")
    }

    /// One agent chat tab of `session`, running on `host`, with the notice its daemon posted.
    static func chatTab(_ surface: UInt64, session: String?, host: String, title: String,
                        notice: (UInt64, NotificationLevel, unread: Bool)? = nil) -> TabSnapshot {
        var tab = TabSnapshot(surface: SurfaceID(rawValue: surface), kind: .conversation, title: title,
                              notification: notice.map { TabNotification(notification: NotificationID(rawValue: $0.0), unread: $0.unread, level: $0.1) })
        tab.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: host, session: session, harness: "claude"))
        return tab
    }

    /// A machine's daemon tree holding `tabs` in one pane.
    static func tree(_ tabs: [TabSnapshot]) -> DaemonStore {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: tabs)
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        return store
    }

    /// The view's rows (`panel`) and the chats its row actions write through.
    static func feed(local: [AgentActivityLane], machines: AgentPriorityChats.Machines,
                     checksFailing: @escaping @MainActor (AgentActivityLane) -> Bool = { _ in false })
        -> (panel: @MainActor () -> SidebarPriorityPanel?, chats: AgentPriorityChats) {
        let store = AgentLaneStore()
        store.lanes = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        let chats = AgentPriorityChats(marks: AgentPriorityMarks(defaults: nil), stores: [store], machines: machines,
                                       checksFailing: checksFailing) { _, _ in }
        let feed = SidebarPriorityFeed(settings: .init(enabled: { true }, shown: { true }),
                                       hooks: .init(shortcut: { nil }, open: { _ in }, rowAction: { _ in }, toggleShown: {}), chats: chats)
        return ({ feed.panel() }, chats)
    }

    @Test func aChatOnACloudOrSSHMachineIsRankedWithThisMacsChats() throws {
        let vm = Self.tree([
            Self.chatTab(1, session: "vm-asks", host: "install:vm", title: "Fix the relay", notice: (11, .warning, unread: true)),
            Self.chatTab(2, session: "vm-done", host: "install:vm", title: "Bump deps", notice: (12, .info, unread: true)),
            Self.chatTab(3, session: "vm-broke", host: "install:vm", title: "Run CI", notice: (13, .error, unread: true)),
            Self.chatTab(4, session: "vm-quiet", host: "install:vm", title: "Read logs", notice: (14, .warning, unread: false)),
            // A new chat that has no session yet is no row.
            Self.chatTab(5, session: nil, host: "install:vm", title: "New chat"),
        ])
        let box = Self.tree([Self.chatTab(1, session: "box-asks", host: "install:box", title: "Deploy", notice: (21, .warning, unread: true))])
        let feed = Self.feed(local: [Self.lane("mac-working", .working, ago: 5), Self.lane("mac-done", .idle, ago: 20, unread: true)],
                             machines: .init(remote: { [SidebarPriorityMachine(name: "gpu-box", store: vm),
                                                        SidebarPriorityMachine(name: "big-blue", store: box)] },
                                             peer: { _ in nil }, local: { nil }))
        let entries = try #require(feed.panel()).entries
        let ids = entries.map(\.id)
        #expect(Set(ids) == ["vm-asks", "box-asks", "vm-done", "mac-done", "vm-broke", "mac-working", "vm-quiet"])
        // Ranked with the rest: what needs the person first, then unseen results, failures, working, idle.
        #expect(entries.prefix(2).allSatisfy { $0.state == .needsYou })
        #expect(Set(entries[2...3].map(\.id)) == ["vm-done", "mac-done"])
        #expect(entries[4].id == "vm-broke" && entries[4].state == .failed)
        #expect(entries[5].id == "mac-working")
        #expect(entries.last?.id == "vm-quiet" && entries.last?.state == .idle)
        // Each remote row names its machine by the sidebar's name for it; this Mac's rows carry none.
        #expect(entries.first { $0.id == "vm-asks" }?.machine == "gpu-box")
        #expect(entries.first { $0.id == "box-asks" }?.machine == "big-blue")
        #expect(entries.first { $0.id == "vm-asks" }?.title == "Fix the relay")
        #expect(entries.first { $0.id == "mac-working" }?.machine == nil)
        #expect(feed.chats.lane("vm-asks")?.state == .input, "a remote row's actions find its chat")
        #expect(feed.chats.entries().map(\.id) == ids, "the row actions rank the same rows")
    }

    @Test func aPeerChatNamesItsMachineAndThisMacIsTaggedOnlyWhenAsked() throws {
        var localTag: String?
        // The peer's chat also shows on that machine's own tree: one row, named once.
        let mini = Self.tree([Self.chatTab(1, session: "peer-asks", host: "install:mini", title: "Mirror", notice: (31, .warning, unread: true))])
        let machines = AgentPriorityChats.Machines(remote: { [SidebarPriorityMachine(name: "Studio Mini", store: mini)] },
                                                    peer: { $0 == "mini" ? "Studio Mini" : nil }, local: { localTag })
        let feed = Self.feed(local: [Self.lane("peer-asks", .input, ago: 1, peer: "mini"),
                                     Self.lane("other-peer", .working, ago: 2, peer: "lab-box"),
                                     Self.lane("mac", .idle, ago: 3)], machines: machines)
        var entries = try #require(feed.panel()).entries
        #expect(entries.filter { $0.id == "peer-asks" }.count == 1)
        #expect(entries.first { $0.id == "peer-asks" }?.machine == "Studio Mini", "a peer resolves to its machine's name")
        #expect(entries.first { $0.id == "other-peer" }?.machine == "lab-box", "a peer no machine matches keeps its name")
        #expect(entries.first { $0.id == "mac" }?.machine == nil, "this Mac's rows have no tag by default")

        localTag = "cosmic-gray"
        entries = try #require(feed.panel()).entries
        #expect(entries.first { $0.id == "mac" }?.machine == "cosmic-gray", "sidebar.showLocalMachine tags this Mac's rows")
        #expect(entries.first { $0.id == "peer-asks" }?.machine == "Studio Mini")
    }

    @Test func aRemoteRowIsNeverRedCIAndMarksReadAsItsNoticeAllows() throws {
        let vm = Self.tree([
            Self.chatTab(1, session: "vm-asks", host: "install:vm", title: "Fix", notice: (41, .warning, unread: true)),
            Self.chatTab(2, session: "vm-done", host: "install:vm", title: "Bump", notice: (42, .info, unread: true)),
            Self.chatTab(3, session: "vm-quiet", host: "install:vm", title: "Read"),
        ])
        // Every chat's checks "fail": only this Mac's chat can be Red CI; a remote tab has no pull request.
        let feed = Self.feed(local: [Self.lane("mac-working", .working, ago: 5)],
                             machines: .init(remote: { [SidebarPriorityMachine(name: "gpu-box", store: vm)] }, peer: { _ in nil }, local: { nil }),
                             checksFailing: { _ in true })
        let entries = try #require(feed.panel()).entries
        let row = { (id: String) in entries.first { $0.id == id } }
        #expect(row("mac-working")?.state == .ciFailing)
        #expect(feed.chats.failingChecks == ["mac-working"])
        #expect(row("vm-asks")?.state == .needsYou && row("vm-asks")?.canMarkRead == false)
        #expect(row("vm-done")?.state == .done && row("vm-done")?.canMarkRead == true)
        #expect(row("vm-quiet")?.state == .idle && row("vm-quiet")?.canMarkRead == false)
        // Marking the remote result read drops it to idle until that machine posts a new notice.
        #expect(feed.chats.markRead("vm-done"))
        #expect(try #require(feed.panel()).entries.first { $0.id == "vm-done" }?.state == .idle)
    }
}
