import CmuxNextHibernation
import CmuxNextSettings
import Testing

/// ``ContentDiscardPlanner/plan(_:for:pace:timed:)``: content whose policies set different timeouts
/// (page tabs) plans against each one's own timeout, the most overdue goes first
/// within one pass, and the next look is the soonest one any of them asks for.
@Suite struct ContentDiscardPlannerTimeoutsTests {
    let planner = ContentDiscardPlanner()
    let onePerPass = ContentDiscardPlanner.Pace(perPass: 1, interval: 1, minimumHidden: 0)

    func timed(_ key: String, hiddenFor: Double, timeout: Double) -> ContentDiscardPlanner.TimedCandidate {
        ContentDiscardPlanner.TimedCandidate(ContentDiscardPlanner.Candidate(key: key, kind: .internalPage, hiddenFor: hiddenFor),
                                             timeout: timeout)
    }

    @Test func eachCandidateIsDueAtItsOwnTimeoutAndTheMostOverdueGoesFirst() {
        let plan = planner.plan(.fallback, for: .proactive, pace: onePerPass, timed: [
            timed("settings", hiddenFor: 700, timeout: 600),
            timed("passwords", hiddenFor: 300, timeout: 60),
            timed("keys", hiddenFor: 100, timeout: 600),
        ])
        #expect(plan.due == ["passwords"], "240 s past its minute beats 100 s past ten minutes")
        #expect(plan.nextCheck == 1, "the next due one comes on the next pass")
    }

    @Test func nothingDueLooksAgainWhenTheSoonestTimeoutEnds() {
        let plan = planner.plan(.fallback, for: .proactive, pace: onePerPass, timed: [
            timed("settings", hiddenFor: 100, timeout: 600),
            timed("passwords", hiddenFor: 20, timeout: 60),
        ])
        #expect(plan.due.isEmpty)
        #expect(plan.nextCheck == 40)
    }

    @Test func protectedContentStaysAtEveryTimeout() {
        var edited = ContentDiscardPlanner.Candidate(key: "editor", kind: .internalPage, hiddenFor: 7_200)
        edited.hasUnsavedEdits = true
        let plan = planner.plan(.fallback, for: .urgent, pace: onePerPass,
                                timed: [ContentDiscardPlanner.TimedCandidate(edited, timeout: 60)])
        #expect(plan.due.isEmpty)
        #expect(plan.exemptions["editor"] == .unsavedEdits)
    }

    @Test func policiesNameTheirTimeouts() {
        #expect(ContentDiscardPolicy.standard.timeout == 600)
        #expect(ContentDiscardPolicy.afterHidden(.milliseconds(1_500)).timeout == 1.5)
        #expect(ContentDiscardPolicy.never.timeout == nil)
    }
}
