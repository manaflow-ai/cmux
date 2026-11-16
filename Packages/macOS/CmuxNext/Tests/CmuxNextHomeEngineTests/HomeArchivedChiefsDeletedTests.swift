import CmuxHomeCore
@testable import CmuxNextHomeEngine
import Testing

/// CMUX-40: after Delete Chief, the deleted Chief's whole conversation came back. The owner's Home
/// list leaves a deleted Chief's direct conversation out (`home-inbox` `deleted_chiefs`), and the
/// page took a conversation the list does not have for one that is about to be listed, so it opened
/// (or kept showing) the deleted Chief's conversation, with all of its history.
@MainActor struct HomeArchivedChiefsDeletedTests {
    private let me = ParticipantID("user_local")
    private let deleted = "agent_01jdeletedchief0000000000"
    private let conversations: [String: [String]] = [
        "conv_deleted": ["user_local", "agent_01jdeletedchief0000000000"],
        "conv_group": ["user_local", "agent_01jdeletedchief0000000000", "user_austin"],
        "conv_new": ["user_local", "agent_01jnewchief00000000000000"],
    ]

    private func participants(_ id: String) -> [String] { conversations[id] ?? [] }

    @Test func aDeletedChiefsUnlistedConversationNeverOpensByItself() {
        let hidden = HomeArchivedChiefs([deleted], me: me)
        #expect(hidden.openable("conv_deleted", listed: [], participants: participants) == nil,
                "the owner no longer lists it, and it is still the deleted Chief's")
    }

    @Test func aNewChiefsConversationNotListedYetStillOpens() {
        let hidden = HomeArchivedChiefs([deleted], me: me)
        #expect(hidden.openable("conv_new", listed: [], participants: participants) == "conv_new")
        #expect(hidden.openable("conv_unknown", listed: [], participants: participants) == "conv_unknown",
                "a conversation the owner does not know yet opens once listed")
        #expect(hidden.openable("conv_deleted", listed: []) == "conv_deleted",
                "with no participants known it stays as before")
    }

    @Test func onlyTheDeletedChiefsDirectConversationIsHidden() {
        let hidden = HomeArchivedChiefs([deleted], me: me)
        #expect(hidden.hides(participants: participants("conv_deleted")))
        #expect(!hidden.hides(participants: participants("conv_group")), "a group with that Chief stays")
        #expect(!hidden.hides(participants: participants("conv_new")))
        #expect(!HomeArchivedChiefs([], me: me).hides(participants: participants("conv_deleted")))
    }
}
