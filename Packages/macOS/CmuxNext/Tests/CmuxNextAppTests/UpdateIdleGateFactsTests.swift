import CmuxNextAgentPane
@testable import CmuxNextDaemonService
import CmuxUpdater
import Testing

/// Update When Idle reads drafts and background work only from an acpmux that serves them: a session
/// summary omits `hasDraft` and `workingBelow` when false, and an older acpmux omits them always, so a
/// census from a daemon without `session-idle-facts-v1` is unknown and the install holds (review of
/// #47272 at 5c4026fb: "Fail closed on missing facts").
struct UpdateIdleGateFactsTests {
    private func census(drafts: Int = 0, workingBelow: Int = 0, inTurn: Int = 0, known: Bool) -> AcpmuxSessionCensus {
        var census = AcpmuxSessionCensus(live: 2, inTurn: inTurn)
        census.drafts = drafts
        census.workingBelow = workingBelow
        census.idleFactsKnown = known
        return census
    }

    @Test func aCensusWithoutTheIdleFactsIsUnknown() {
        // An older acpmux: no draft and no background work listed, which is not "none".
        #expect(UpdateIdleGate.agentFacts(census: census(known: false), blockers: .empty, newChatDrafts: 0) == nil)
    }

    @Test func noCensusIsUnknown() {
        #expect(UpdateIdleGate.agentFacts(census: nil, blockers: .empty, newChatDrafts: 0) == nil)
    }

    @Test func anUnreadableMirrorOrNewChatDraftCountIsUnknown() {
        #expect(UpdateIdleGate.agentFacts(census: census(known: true), blockers: .daemonUnavailable, newChatDrafts: 0) == nil)
        #expect(UpdateIdleGate.agentFacts(census: census(known: true), blockers: .empty, newChatDrafts: nil) == nil)
    }

    @Test func knownFactsCountTurnsBackgroundWorkAndDrafts() throws {
        let facts = try #require(UpdateIdleGate.agentFacts(
            census: census(drafts: 1, workingBelow: 2, inTurn: 1, known: true), blockers: .empty, newChatDrafts: 3))
        #expect(facts.runningTurns == 3)
        #expect(facts.unsentDrafts == 4)
    }

    @Test func aKnownQuietCensusIsClear() throws {
        let facts = try #require(UpdateIdleGate.agentFacts(census: census(known: true), blockers: .empty, newChatDrafts: 0))
        #expect(facts.runningTurns == 0)
        #expect(facts.unsentDrafts == 0)
    }

    @Test func theTabMirrorsTurnsWinWhenHigher() throws {
        let facts = try #require(UpdateIdleGate.agentFacts(
            census: census(known: true), blockers: UpdateRelaunchBlockers(busyAgentCount: 2, runningCommandCount: 0),
            newChatDrafts: 0))
        #expect(facts.runningTurns == 2)
    }
}
