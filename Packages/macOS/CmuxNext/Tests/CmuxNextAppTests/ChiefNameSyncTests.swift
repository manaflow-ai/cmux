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

    /// A header rename of a Chief of this Mac renames its registry record (whose owner retitles its
    /// conversation), not only the conversation title the list never read.
    @Test func aLocalRenameWritesTheChiefsRecord() {
        let rename = HomeLocalChiefRename(chief: "agent_mux", name: " Mario ")
        #expect(rename.operation == "chief.profile.update")
        #expect(rename.params["chief"] == .string("agent_mux"))
        #expect(rename.params["display_name"] == .string("Mario"))
        #expect(rename.idempotencyKey("k") == "home-chief-rename-agent_mux-k")
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
