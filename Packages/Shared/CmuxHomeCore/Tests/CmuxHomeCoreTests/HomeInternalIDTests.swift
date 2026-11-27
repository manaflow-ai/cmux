import Foundation
import Testing
@testable import CmuxHomeCore

/// A person never reads an internal id (`addr_…`, `user_…`) as a name: the raw `addr_` id of an
/// invited email address once titled a Home row (2026-10-19).
@Suite struct HomeInternalIDTests {
    @Test(arguments: [
        "addr_ABREQ2MXXDJ3CH86MMYYKA0FPC", "user_00000000000000000peer", "agent_EBXXF1MYT6B13HFYC1NVTQ9GPK",
        "conv_dm_0Y05MEWEFMQQB63VDHQB9MXAJS", "inv_0000000000000000000000000A", "user_local",
    ])
    func internalIDsAreRecognized(_ text: String) {
        #expect(text.isHomeInternalID)
    }

    @Test(arguments: ["Austin", "a***@manaflow.ai", "austin@manaflow.ai", "user name", "Addr Smith", "addr", "", "Chief"])
    func namesAreNotInternalIDs(_ text: String) {
        #expect(!text.isHomeInternalID)
    }

    @Test func aDirectMessageTitleNeverShowsAnInternalID() {
        let me = Participant(id: ParticipantID("user_local"), kind: .human, displayName: "Lawrence")
        let invited = Participant(id: ParticipantID("addr_ABREQ2MXXDJ3CH86MMYYKA0FPC"), kind: .human,
                                  displayName: "addr_ABREQ2MXXDJ3CH86MMYYKA0FPC", membership: .invited)
        let summary = ConversationSummary(id: ConversationID("conv_dm_0Y05MEWEFMQQB63VDHQB9MXAJS"),
                                          participants: [me, invited], createdAt: .distantPast, updatedAt: .distantPast)
        #expect(summary.displayTitle(me: me.id) == "")
    }

    @Test func anInvitedPersonIsNamedByTheMaskedAddress() {
        let me = Participant(id: ParticipantID("user_local"), kind: .human, displayName: "Lawrence")
        let invited = Participant(id: ParticipantID("addr_ABREQ2MXXDJ3CH86MMYYKA0FPC"), kind: .human, displayName: "",
                                  membership: .invited, invitedContact: "a***@manaflow.ai")
        let summary = ConversationSummary(id: ConversationID("conv_dm_0Y05MEWEFMQQB63VDHQB9MXAJS"),
                                          participants: [me, invited], createdAt: .distantPast, updatedAt: .distantPast)
        #expect(summary.displayTitle(me: me.id) == "a***@manaflow.ai")
        #expect(invited.visibleName == "a***@manaflow.ai")
    }
}
