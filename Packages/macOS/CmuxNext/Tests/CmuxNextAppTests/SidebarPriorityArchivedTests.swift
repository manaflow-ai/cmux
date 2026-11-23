import AppKit
import CmuxNextActions
import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextSidebar
import Foundation
import Testing

/// The Priority view's Archived fold and Restore (the Claude app's archived sessions): acpmux's `archived` tag
/// lists a chat under Archived (folded by default, newest archive first, a page at a time), off the ranked rows;
/// Restore drops the tag and lists it again; a row's Archive lists it under Archived at once.
@MainActor
struct SidebarPriorityArchivedTests {
    static let socket = "/tmp/pv-archived-acpmux.sock"

    @MainActor final class Fixture {
        let store = AgentLaneStore()
        let turns = AgentTurnStateStore()
        let chats: AgentPriorityChats
        let archives: AsyncStream<String>
        let restores: AsyncStream<String>

        init(refuseRestore: Bool = false) {
            store.socketPath = SidebarPriorityArchivedTests.socket
            store.live = true
            for id in ["open", "shelved"] {
                store.lanes[id] = AgentActivityLane(id: id, name: id, title: "Chat \(id)", peer: nil, parent: nil, state: .idle,
                                                    since: Date().addingTimeInterval(-60), error: nil, unread: true, project: "cmux")
            }
            let (archives, archiveSink) = AsyncStream.makeStream(of: String.self)
            let (restores, restoreSink) = AsyncStream.makeStream(of: String.self)
            self.archives = archives
            self.restores = restores
            chats = AgentPriorityChats(marks: AgentPriorityMarks(defaults: nil), stores: [store], checksFailing: { _ in false },
                                       archivedChats: turns.archivedChats,
                                       archive: { socket, id in archiveSink.yield("\(socket) \(id)") },
                                       unarchive: { socket, id in
                                           restoreSink.yield("\(socket) \(id)")
                                           if refuseRestore { throw Refused() }
                                       })
        }

        /// acpmux reports `id` archived at `ms` (a `session_changed` with the `archived` tag).
        func reportArchived(_ id: String, title: String, ms: UInt64?, cwd: String = "/src/cmux") {
            let tag: Any = ms.map { String($0) } ?? "1"
            let detail = AgentChatDetail.of(summary: ["cwd": cwd, "tags": ["archived": tag]])
            turns.apply(session: id, state: nil, lastMessage: nil, muted: false, title: title, detail: detail)
        }

        /// acpmux reports `id` with no `archived` tag.
        func reportListed(_ id: String) {
            turns.apply(session: id, state: nil, lastMessage: nil, muted: false, title: "Chat \(id)",
                        detail: AgentChatDetail.of(summary: ["cwd": "/src/cmux"]))
        }

        func feed() -> SidebarPriorityFeed {
            let chats = chats
            return SidebarPriorityFeed(settings: .init(enabled: { true }, shown: { true }),
                                       hooks: .init(shortcut: { nil }, open: { _ in },
                                                    rowAction: { action in
                                                        if case .restore(let id) = action { chats.restore(id) }
                                                    },
                                                    toggleShown: {}),
                                       chats: chats)
        }
    }

    @Test func theArchivedTagReadsItsTime() {
        #expect(AgentChatDetail.archivedAtMs(["tags": ["archived": "1731000000000"]]) == 1_731_000_000_000)
        #expect(AgentChatDetail.archivedAtMs(["tags": ["archived": ["value": "1731000000000"]]]) == 1_731_000_000_000)
        #expect(AgentChatDetail.archivedAtMs(["tags": ["archived": "1"]]) == nil, "a tag with no time is still archived")
        #expect(AgentChatDetail.archivedAtMs(["tags": ["archived": ["value": "1731000000000", "expires_at": 1]]]) == nil,
                "an expired tag is not in force")
        #expect(AgentChatDetail.of(summary: ["tags": ["archived": "1731000000000"]])?.archivedAtMs == 1_731_000_000_000)
    }

    @Test func theStoreListsArchivedChatsAsTheyArriveAndKeepsThemWhileTheWatchReconnects() {
        let fixture = Fixture()
        fixture.reportArchived("old", title: "Old chat", ms: 1_000)
        fixture.reportArchived("new", title: "New chat", ms: 2_000)
        fixture.reportArchived("timeless", title: "A chat", ms: nil)
        #expect(fixture.turns.archivedChats.newest(limit: 10).map(\.id) == ["new", "old", "timeless"])
        #expect(fixture.turns.archivedChats.newest(limit: 1).map(\.id) == ["new"])

        fixture.turns.clearLive()
        #expect(fixture.turns.archivedChats.count == 3, "a closing watch knows nothing new")

        fixture.reportListed("old")
        #expect(fixture.turns.archivedChats.newest(limit: 10).map(\.id) == ["new", "timeless"], "unarchived elsewhere")
    }

    @Test func theFoldIsFoldedByDefaultAndHoldsNoRowsUntilOpened() throws {
        let fixture = Fixture()
        for index in 0..<(SidebarArchivedChats.pageSize + 5) {
            fixture.reportArchived("a\(index)", title: "Archived \(index)", ms: UInt64(1_000 + index))
        }
        let feed = fixture.feed()
        let folded = try #require(feed.panel()).archived
        #expect(folded.folded)
        #expect(folded.count == SidebarArchivedChats.pageSize + 5)
        #expect(folded.rows.isEmpty, "folded, it builds no row")

        feed.perform(.setArchivedFolded(false))
        let open = try #require(feed.panel()).archived
        #expect(open.rows.count == SidebarArchivedChats.pageSize)
        #expect(open.rows.first?.id == "a\(SidebarArchivedChats.pageSize + 4)", "the newest archive first")
        #expect(open.rows.first?.project == "cmux")
        #expect(open.hiddenCount == 5)

        feed.perform(.showMoreArchived)
        #expect(try #require(feed.panel()).archived.rows.count == SidebarArchivedChats.pageSize + 5)
    }

    @Test func anArchivedChatLeavesTheRankedRows() throws {
        let fixture = Fixture()
        #expect(try #require(fixture.feed().panel()).entries.map(\.id).sorted() == ["open", "shelved"])
        fixture.reportArchived("shelved", title: "Chat shelved", ms: 5_000)
        let panel = try #require(fixture.feed().panel())
        #expect(panel.entries.map(\.id) == ["open"])
        #expect(panel.archived.count == 1)
    }

    @Test func aRowsArchiveListsTheChatUnderArchivedAtOnce() async throws {
        let fixture = Fixture()
        #expect(fixture.chats.archive("shelved"))
        #expect(fixture.turns.archivedChats.contains("shelved"))
        #expect(fixture.chats.isArchived("shelved"))
        var archives = fixture.archives.makeAsyncIterator()
        #expect(await archives.next() == "\(Self.socket) shelved")
    }

    /// An archive's Undo (toasts v2) takes the chat out of the Archived fold too, not only back into the ranked rows.
    @Test func anArchivesUndoLeavesTheArchivedFold() async throws {
        let fixture = Fixture()
        #expect(fixture.chats.archive("shelved"))
        fixture.chats.unarchive("shelved", socketPath: Self.socket)
        #expect(!fixture.chats.isArchived("shelved"))
        var restores = fixture.restores.makeAsyncIterator()
        #expect(await restores.next() == "\(Self.socket) shelved")
    }

    @Test func restoreListsTheChatAgainAndAsksAcpmuxToDropTheTag() async throws {
        let fixture = Fixture()
        fixture.reportArchived("shelved", title: "Chat shelved", ms: 5_000)
        let feed = fixture.feed()
        feed.perform(.restore("shelved"))
        #expect(!fixture.turns.archivedChats.contains("shelved"))
        #expect(try #require(feed.panel()).entries.map(\.id).contains("shelved"))
        var restores = fixture.restores.makeAsyncIterator()
        #expect(await restores.next() == "\(Self.socket) shelved")
        #expect(!fixture.chats.restore("open"), "a chat that is not archived has nothing to restore")
    }

    @Test func aRefusedRestoreListsTheChatUnderArchivedAgain() async throws {
        let fixture = Fixture(refuseRestore: true)
        fixture.reportArchived("shelved", title: "Chat shelved", ms: 5_000)
        #expect(fixture.chats.restore("shelved"))
        var restores = fixture.restores.makeAsyncIterator()
        _ = await restores.next()
        for _ in 0..<50 where !fixture.turns.archivedChats.contains("shelved") { await Task.yield() }
        #expect(fixture.turns.archivedChats.contains("shelved"))
    }

    @Test func anArchivedChatsMenuOffersRestoreInsteadOfTheRankedRowsActions() throws {
        let fixture = Fixture()
        let registry = ActionRegistry.standard()
        // Restore is new to the action catalog: until the app's pinned FFI lists it, nothing to check here.
        guard registry.action(for: SidebarPriorityRowActions.restore) != nil else { return }
        let actions = SidebarPriorityRowActions(chats: fixture.chats)
        actions.bind(into: registry)
        actions.bindArchive(into: registry) { _ in }
        fixture.reportArchived("shelved", title: "Chat shelved", ms: 5_000)
        func ids(_ chat: String) -> [ActionID] {
            Self.leafItems(registry.makeContextMenu(for: .priorityRow, target: SidebarPriorityRowActions.target(chat)))
                .compactMap { ActionRegistry.menuRun(of: $0)?.id }
        }
        #expect(ids("shelved") == [SidebarPriorityRowActions.restore])
        #expect(!ids("open").contains(SidebarPriorityRowActions.restore))
        #expect(registry.perform(SidebarPriorityRowActions.restore,
                                 invocation: ActionInvocation(target: SidebarPriorityRowActions.target("shelved"))))
        #expect(!fixture.turns.archivedChats.contains("shelved"))
    }

    @Test func theFoldCountsWhatWaitsPastItsPage() {
        #expect(!SidebarArchivedChats(count: 0).isVisible)
        #expect(SidebarArchivedChats(count: 40).hiddenCount == 0, "folded, nothing waits past a page")
        #expect(SidebarArchivedChats(count: 40, rows: [SidebarArchivedChat(id: "x", title: "x")]).rows.isEmpty, "folded holds no row")
        let open = SidebarArchivedChats(count: 40, rows: (0..<20).map { SidebarArchivedChat(id: "\($0)", title: "\($0)") }, folded: false)
        #expect(open.hiddenCount == 20)
    }

    private static func leafItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in item.submenu.map(leafItems) ?? (item.isSeparatorItem ? [] : [item]) }
    }
}

private struct Refused: Error {}
