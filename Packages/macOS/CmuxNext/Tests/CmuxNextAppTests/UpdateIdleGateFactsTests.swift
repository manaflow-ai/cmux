@testable import CmuxNextAgentPane
@testable import CmuxNextDaemonService
import CmuxUpdater
import Foundation
import Testing

/// Update When Idle reads drafts only from an acpmux that serves them: a session
/// summary omits `hasDraft` when false, and an older acpmux omits them always, so a
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

    @Test func knownFactsCountDrafts() {
        #expect(UpdateIdleGate.agentFacts(
            census: census(drafts: 1, known: true), blockers: .empty, newChatDrafts: 3) == 4)
    }

    @Test func aKnownQuietCensusIsClear() {
        #expect(UpdateIdleGate.agentFacts(census: census(known: true), blockers: .empty, newChatDrafts: 0) == 0)
    }

    /// Leo, 2026-11-22: "auto be de facto able to click the restart button". A running turn, background work
    /// or a busy tab does not hold the away relaunch: they carry across it (acpmux `route_switch.rs`).
    @Test func turnsAndBackgroundWorkDoNotCount() {
        #expect(UpdateIdleGate.agentFacts(
            census: census(workingBelow: 2, inTurn: 1, known: true),
            blockers: UpdateRelaunchBlockers(busyAgentCount: 2, runningCommandCount: 0), newChatDrafts: 0) == 0)
    }
}

/// A census stands only for ``UpdateAgentActivity/freshFor``: a read that hangs or fails must not leave an old
/// clear answer authorizing an install over a turn that started since (review of #47272 at 4ac735af).
@MainActor struct UpdateAgentActivityFreshnessTests {
    private final class Clock {
        var now = ContinuousClock.now
    }

    private static func environment() -> AcpmuxEnvironment {
        let home = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("uaf-\(UUID().uuidString.prefix(8))", isDirectory: true)
        return AcpmuxEnvironment(executable: URL(fileURLWithPath: "/usr/bin/false"), home: home,
                                 socketPath: home.appendingPathComponent("acpmux.sock").path,
                                 daemonArguments: [], childEnvironment: [:])
    }

    private static func clear() -> AcpmuxSessionCensus {
        var census = AcpmuxSessionCensus()
        census.idleFactsKnown = true
        return census
    }

    @Test func aClearCensusExpiresWhenNoNewAnswerComes() {
        let clock = Clock()
        let activity = UpdateAgentActivity(environment: Self.environment(), clock: { clock.now })
        #expect(activity.census == nil)
        activity.record(Self.clear())
        #expect(activity.census != nil)
        // The next reads hang: the clear answer stands only until it is too old.
        clock.now += UpdateAgentActivity.freshFor - .milliseconds(1)
        #expect(activity.census != nil)
        clock.now += .milliseconds(1)
        #expect(activity.census == nil)
        #expect(UpdateIdleGate.agentFacts(census: activity.census, blockers: .empty, newChatDrafts: 0) == nil)
    }

    @Test func aFailedReadDropsTheLastAnswer() {
        let clock = Clock()
        let activity = UpdateAgentActivity(environment: Self.environment(), clock: { clock.now })
        activity.record(Self.clear())
        activity.record(nil)
        #expect(activity.census == nil)
    }

    @Test func noAcpmuxIsAKnownEmptyCensus() throws {
        let activity = UpdateAgentActivity(environment: nil)
        let census = try #require(activity.census)
        #expect(census.idleFactsKnown)
        #expect(census.inTurn == 0 && census.drafts == 0 && census.workingBelow == 0)
    }
}
