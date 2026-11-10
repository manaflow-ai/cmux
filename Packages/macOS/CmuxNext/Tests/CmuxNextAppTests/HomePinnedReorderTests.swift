import AppKit
import CmuxHomeCore
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextHome
@testable import CmuxNextHomeModel
@testable import CmuxNextHomeEngine
import CmuxNextTestSupport
import Foundation
@testable import MessagesLabSidebar
import Testing

/// Reordering the pinned grid of Home's conversation list by drag (the user, 2026-11-05: "reordering
/// pinned stuff in imessage doesnt work"). A drop on the Messages page runs `HomeSidebarSource.place`
/// with the slot the tile landed on, over the pins people have:
/// the main Chief, other Chiefs and a DM pinned with the local owner, a conversation no owner
/// lists yet pinned on this Mac, and a Chief no owner lists (pinned by default). Every drop must
/// land exactly where the tile was drawn, the main Chief included, and the order must be the same after a relaunch.
@MainActor
@Suite(.serialized) struct HomePinnedReorderTests {
    static let maya = CmuxHomeCore.ConversationID("conv_maya")
    static let now = Date(timeIntervalSince1970: 1_800_010_000)

    /// The store's rows: the launch suite's conversations plus a DM with Maya that no owner lists.
    static func storeRows() -> [InboxRow] {
        let me = HomeLaunchListTests.me
        let maya = Participant(id: ParticipantID("user_maya"), kind: .human, displayName: "Maya")
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let summary = CmuxHomeCore.ConversationSummary(id: Self.maya, title: "", participants: [me, maya], createdAt: at,
                                                       updatedAt: at.addingTimeInterval(10 * 60))
        var mirror = HomeMirror()
        _ = mirror.apply(inbox: InboxSnapshot(me: me, conversations: [summary], rev: 1))
        return HomeLaunchListTests.storeRows() + mirror.inboxRows(log: IntentLog())
    }

    /// One launch of Home's list: the owners and this Mac's pin store (`defaults`). The list is drawn by
    /// the React Messages page now; a drop there runs `HomeSidebarSource.place` with the slot it landed
    /// on, which is what `drag(from:to:)` does here.
    @MainActor final class Home {
        let local = HomeInboxSource(owners: ["local"])
        let cloud = HomeInboxSource(owners: ["cloud"])
        let source: HomeSidebarSource

        /// `replies`: the owners' answers (the last launch's edited rows on a relaunch).
        init(defaults: UserDefaults, replies: (local: HomeInboxRequest.Response, cloud: HomeInboxRequest.Response)) {
            let rows = HomePinnedReorderTests.storeRows()
            source = HomeSidebarSource(
                store: HomePinStore(defaults: defaults), inboxes: [local, cloud], account: { HomeLaunchListTests.account },
                rows: { rows }, me: { HomeLaunchListTests.me.id }, contacts: { [] },
                chiefRoster: { HomeLaunchListTests.roster(rows: rows, cloudRead: true) })
            source.reloadPins()
            local.accept(replies.local)
            cloud.accept(replies.cloud)
        }

        var grid: [CmuxHomeCore.ConversationID] { source.model(now: HomePinnedReorderTests.now).pinned.map(\.id) }

        /// The owners' rows as this launch left them (what each owner answers after the writes).
        var replies: (local: HomeInboxRequest.Response, cloud: HomeInboxRequest.Response)? {
            guard let local = local.reply, let cloud = cloud.reply else { return nil }
            return (local, cloud)
        }

        /// Drops the tile at `from` of the grid on slot `to`, as the page's drop does.
        func drag(from: Int, to: Int) {
            source.place(grid[from], at: to)
        }
    }

    static func defaults() -> UserDefaults {
        let suite = "cmux.tests.homePinnedReorder.\(UUID().uuidString)"
        let defaults = UserDefaults(testSuiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        // Maya's DM is pinned on this Mac (no owner lists it, so its pin stays here).
        HomePinStore(defaults: defaults).save(HomePins(pinned: [maya]), account: HomeLaunchListTests.account)
        return defaults
    }

    /// `ids` with the one at `from` moved to `to` (the grid the drop should leave).
    static func moved(_ ids: [CmuxHomeCore.ConversationID], from: Int, to: Int) -> [CmuxHomeCore.ConversationID] {
        var ids = ids
        let id = ids.remove(at: from)
        ids.insert(id, at: to)
        return ids
    }

    /// (from, to) in the drawn grid of five: the main Chief to the end, the last tiles (pins no
    /// owner lists) to the front, a tile into the middle, an owner's pin after this Mac's.
    @Test(arguments: [(0, 4), (3, 0), (4, 0), (0, 1), (1, 2), (2, 3), (3, 1)])
    func aDroppedTileLandsWhereItWasDrawn(from: Int, to: Int) throws {
        let home = try Home(defaults: Self.defaults(), replies: HomeLaunchListTests.liveReplies())
        let before = home.grid
        try #require(before.count == 5, "five pinned tiles: \(before)")
        home.drag(from: from, to: to)
        let expected = Self.moved(before, from: from, to: to)
        #expect(home.grid == expected, "the drop of tile \(from) on slot \(to) left \(home.grid), not \(expected)")
    }

    @Test func theMainChiefCanBeDroppedAfterTheOtherPins() throws {
        let home = try Home(defaults: Self.defaults(), replies: HomeLaunchListTests.liveReplies())
        let main = CmuxHomeCore.ConversationID("conv_agent_hosted")
        let at = try #require(home.grid.firstIndex(of: main), "the main Chief is pinned")
        home.drag(from: at, to: home.grid.count - 1)
        #expect(home.grid.last == main, "the main Chief stays where it was dropped: \(home.grid)")
    }

    @Test func theNewOrderIsKeptAfterARelaunch() throws {
        let defaults = Self.defaults()
        let first = try Home(defaults: defaults, replies: HomeLaunchListTests.liveReplies())
        first.drag(from: 3, to: 0)
        first.drag(from: 1, to: 3)
        let order = first.grid
        let replies = try #require(first.replies)
        let relaunched = Home(defaults: defaults, replies: replies)
        #expect(relaunched.grid == order, "after a relaunch the grid is \(relaunched.grid), not \(order)")
    }

    /// Pin on a tile that is already pinned (`home.togglePin` with `pinned: true`, the row's Pin) keeps
    /// its place: an owner's pin, this Mac's pin, a default pin and the main Chief alike, after a relaunch too.
    @Test(arguments: 0..<5)
    func pinningAPinnedTileKeepsItsPlace(at index: Int) throws {
        let defaults = Self.defaults()
        let home = try Home(defaults: defaults, replies: HomeLaunchListTests.liveReplies())
        let before = home.grid
        try #require(before.count == 5, "five pinned tiles: \(before)")
        home.source.setPinned(true, before[index])
        #expect(home.grid == before, "pinning tile \(index) again left \(home.grid), not \(before)")
        let replies = try #require(home.replies)
        let relaunched = Home(defaults: defaults, replies: replies)
        #expect(relaunched.grid == before, "after a relaunch the grid is \(relaunched.grid), not \(before)")
    }

    @Test func pinsSavedBeforeThisChangeStillLoad() throws {
        let saved = Data(#"{"pinned":["conv_a","conv_b"],"unpinned":["conv_c"]}"#.utf8)
        let pins = try JSONDecoder().decode(HomePins.self, from: saved)
        #expect(pins.pinned == [CmuxHomeCore.ConversationID("conv_a"), CmuxHomeCore.ConversationID("conv_b")])
        #expect(pins.unpinned == [CmuxHomeCore.ConversationID("conv_c")])
        #expect(pins.positions.isEmpty)
    }

    @Test func withOnlyThisMacsPinsTheMainChiefLeadsUntilItIsDropped() {
        let rows = HomeChiefRosterTests.rows
        let roster = HomeChiefRosterTests.roster()
        var pins = HomePins()
        let first = HomeSidebarModel(rows: rows, pins: pins, me: HomeChiefRosterTests.me, chiefRoster: roster)
        #expect(first.pinned.first?.id == HomeChiefRosterTests.hosted, "by default the main Chief leads")
        let shown = first.pinned.map(\.id)
        pins.place(HomeChiefRosterTests.hosted, at: shown.count - 1, shown: shown)
        let dropped = HomeSidebarModel(rows: rows, pins: pins, me: HomeChiefRosterTests.me, chiefRoster: roster)
        #expect(dropped.pinned.last?.id == HomeChiefRosterTests.hosted, "dropped last, the main Chief stays last")
        #expect(dropped.pinned.first?.isMainChief == false)
    }
}
