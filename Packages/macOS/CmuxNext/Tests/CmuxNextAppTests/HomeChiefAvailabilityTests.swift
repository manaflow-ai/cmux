import CmuxHomeCore
import Foundation
import Testing
@testable import CmuxNextApp

/// Home is usable whenever the owner of its conversation answers
/// (home-state-ownership.md section 3). chiefpair-v4 (cmux-lawrence-2,
/// 2026-10-06): with older builds' Chief hosts still running, the migration
/// held the Chief owner back, so Home stayed "waiting for the chief owner",
/// unavailable with Send off, even for a Chief placed on a server whose
/// conversation the cloud proxy serves without that owner.
@Suite struct HomeChiefAvailabilityTests {
    @Test func theMergedConnectionIsOnlineWhenEitherOwnerAnswers() {
        let since = Date(timeIntervalSince1970: 0)
        #expect(HomeSourceRouter.merged(local: .offline(since: since), cloud: .online) == .online,
                "a cloud Chief needs no local owner")
        #expect(HomeSourceRouter.merged(local: .online, cloud: .offline(since: since)) == .online)
        #expect(HomeSourceRouter.merged(local: .connecting, cloud: nil) == .connecting, "no cloud link: the local owner decides")
        #expect(HomeSourceRouter.merged(local: .offline(since: since), cloud: .offline(since: since)) == .offline(since: since))
    }

    @Test func aPlacedChiefShowsWhileTheLocalOwnerIsNotKnown() {
        let placed = CloudChief.parse(["id": "agent_A", "display_name": "Chief", "is_default": true, "rev": 2,
                                       "main_conversation": "conv_A",
                                       "brain_place": ["host": "host_aaaaaaaaaaaaaaaaaaaa", "install": "inst_aaaaaaaaaaaaaaaaaaaa"]])
        // The local owner has not answered (nil): the placed chief shows now;
        // once the owner answers with history, the local Chief takes the tab back.
        #expect(HomeChiefSource.choose(local: nil, localHasHistory: false, placed: placed) == "conv_A")
    }

    @Test func aMigrationOutcomeNeverHoldsTheOwnerBack() {
        for outcome: ChiefMigration.Outcome in [.blocked(["hmchief4"]), .refused("import_out_of_order"), .nothingToDo,
                                                .done(messages: 1, memoryEntries: 1)] {
            #expect(ChiefMigration.publishesOwner(after: outcome), "\(outcome)")
        }
        #expect(ChiefMigration.notice(for: .blocked(["hmchief4"])) != nil)
        #expect(ChiefMigration.notice(for: .nothingToDo) == nil)
    }
}
