import AppKit
import CmuxHomeCore
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextHome
import CmuxNextHomeEngine
import Foundation
import Testing

/// Issue 26393: renaming a Chief left every surface on its own name. The Home list's tile said
/// "Chief" (the registry record), the chat header "Mario" (the conversation title a header rename
/// set), the list "Chief 2 / Chief 3". One name now: the Chief's record, or a rename being saved,
/// read by the tile, the header, the settings card, the tab strip, banners and Send Message….
@MainActor @Suite(.serialized)
struct ChiefNameSyncTests {
    let mario = ConversationID("conv_mux")
    let scout = ConversationID("conv_scout")

    static func rows(_ json: String) throws -> [HomeInboxRequest.Row] {
        try JSONDecoder().decode([HomeInboxRequest.Row].self, from: Data(json.utf8))
    }

    /// This Mac's Chiefs are named by their registry record, the name `home-inbox` gives each Chief
    /// row; a DM or a group is no Chief's, and a raw id is no name.
    @Test func thisMacsChiefsAreNamedByTheirRecord() throws {
        let rows = try Self.rows("""
        [{"id":"conv_mux","kind":"chief","name":"Mario","unread":0,"activity_at":"","chief":"agent_mux","pinned":true,"marked_unread":false},
         {"id":"conv_scout","kind":"chief","name":"  ","unread":0,"activity_at":"","chief":"agent_scout","pinned":false,"marked_unread":false},
         {"id":"conv_dm","kind":"direct","name":"Austin","unread":0,"activity_at":"","pinned":false,"marked_unread":false},
         {"id":"conv_raw","kind":"chief","name":"agent_01BX5ZZKBKACTAV9WEVGEMMVRZ","unread":0,"activity_at":"","pinned":false,"marked_unread":false}]
        """)
        #expect(HomeChiefNames.localRecords(rows) == [mario: "Mario"])
        #expect(HomeChiefNames.localRecords(nil).isEmpty)
    }

    /// A rename shows at once, stays while its record still has the old name, and the record decides
    /// for good once it moves (to the new name, or another device's later one).
    @Test func aRenameShowsAtOnceUntilTheRecordMoves() {
        var names = HomeChiefNames()
        #expect(names.name(of: mario, record: "Chief") == "Chief")
        names.rename(mario, to: " Mario ", record: "Chief")
        #expect(names.name(of: mario, record: "Chief") == "Mario")
        #expect(names.all([mario: "Chief", scout: "Scout"]) == [mario: "Mario", scout: "Scout"], "the other Chief keeps its own")
        names.settle(mario, record: "Chief")
        #expect(names.name(of: mario, record: "Chief") == "Mario", "a read before the save lands keeps the new name")
        names.settle(mario, record: "Mario")
        #expect(!names.isPending(mario))
        #expect(names.name(of: mario, record: "Luigi") == "Luigi", "a later rename elsewhere wins")
        #expect(names.name(of: mario, record: "Chief") == "Chief", "an undo back to the old name shows it, not the settled rename")
    }

    /// Two renames in a row: the second shows through the first one's echo, then its own.
    @Test func aSecondRenameShowsThroughTheFirstsEcho() {
        var names = HomeChiefNames()
        names.rename(mario, to: "Mario", record: "Chief")
        names.rename(mario, to: "Luigi", record: "Chief")
        names.settle(mario, record: "Mario")
        #expect(names.name(of: mario, record: "Mario") == "Luigi")
        names.settle(mario, record: "Luigi")
        #expect(!names.isPending(mario))
        #expect(names.name(of: mario, record: "Luigi") == "Luigi")
    }

    /// A refused save shows the record's name again; a newer rename is not undone by an older refusal.
    @Test func aRefusedSaveRollsBack() {
        var names = HomeChiefNames()
        names.rename(mario, to: "Mario", record: "Chief")
        names.rollBack(mario, name: "Mario")
        #expect(names.name(of: mario, record: "Chief") == "Chief")
        names.rename(mario, to: "Mario", record: "Chief")
        names.rename(mario, to: "Luigi", record: "Chief")
        names.rollBack(mario, name: "Mario")
        #expect(names.name(of: mario, record: "Chief") == "Luigi")
        names.rename(mario, to: "   ", record: "Chief")
        #expect(names.name(of: mario, record: "Chief") == "Luigi", "a blank name renames nothing")
        #expect(HomeChiefNames().name(of: scout, record: nil) == nil, "no record: the conversation's own title")
    }

    /// A header rename of a Chief of this Mac renames its registry record (whose owner retitles its
    /// conversation), not only the conversation title the list never read.
    @Test func aLocalRenameWritesTheChiefsRecord() {
        let rename = HomeLocalChiefRename(chief: "agent_mux", name: " Mario ")
        #expect(rename.operation == "chief.profile.update")
        #expect(rename.params["chief"] == .string("agent_mux"))
        #expect(rename.params["display_name"] == .string("Mario"))
        #expect(rename.idempotencyKey("k") == "home-chief-rename-agent_mux-k")
        let invalid = DaemonError.command(cmd: "chief.profile.update", message: "display_name too long", code: "validation.invalid",
                                          details: .object(["reason": .string("too long")]))
        #expect(HomeLocalChiefRename.failure(invalid) == .invalidName)
        let gone = DaemonError.command(cmd: "chief.profile.update", message: "", code: "operation.failed",
                                       details: .object(["reason": .string("chief_not_found")]))
        #expect(HomeLocalChiefRename.failure(gone) == .notFound)
        let moved = DaemonError.command(cmd: "chief.profile.update", message: "", code: "operation.failed",
                                        details: .object(["reason": .string("rev_mismatch")]))
        #expect(HomeLocalChiefRename.failure(moved) == .changedElsewhere)
        #expect(HomeLocalChiefRename.failure(CancellationError()) == .noConnection)
    }

    /// The app's one rename path: a conversation no Chief record names (a group with a Chief, or
    /// no owner to ask) gets no shown rename, so a refused save never leaves a name behind.
    @Test func theServiceShowsNoRenameForAConversationWithoutARecord() async {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current(["CMUX_NEXT_SHOWCASE": "1"]))
        let home = services.home
        let failure = await home.renameChief(conversation: "conv_launch", to: "Launch v2")
        #expect(failure != nil)
        #expect(home.chiefName(of: ConversationID("conv_launch")) == nil)
        #expect(!home.chiefRenames.isPending(ConversationID("conv_launch")))
        home.chiefRenames.rename(mario, to: "Mario", record: nil)
        #expect(home.chiefName(of: mario) == "Mario", "the service reads the shown rename")
        #expect(home.chiefNames[mario] == "Mario")
    }

    /// Send Message… lists and finds a Chief by its own name, the one its tile shows.
    @Test func sendMessageFindsAChiefByItsName() async throws {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        store.start()
        let deadline = ContinuousClock.now + .seconds(10)
        while !(store.isOnline && !store.rows.isEmpty), ContinuousClock.now < deadline { await Task.yield() }
        let actions = HomeGroupActions(store: store, muting: HomeMessageRoutingTests.NoMuting(), contacts: { [] })
        let chief = ConversationID("conv_chief")
        let routing = HomeMessageRouting(store: store, actions: actions, chief: { chief }, chiefNames: { [chief: "Mario"] })
        #expect(routing.resolve("mario") == chief)
        #expect(routing.recipients().first { $0.value == chief.rawValue }?.title == "Mario")
    }
}
