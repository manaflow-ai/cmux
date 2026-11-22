import CmuxNextBridge
import CmuxNextSettings
import Testing
@testable import CmuxNextApp

/// When hidden pages hibernate (plans/cmux-next/tab-lifecycle.md).
struct HibernationPlannerTests {
    typealias Candidate = HibernationPlanner.Candidate

    @Test func offNeverHibernatesEvenUnderCriticalPressure() {
        let plan = HibernationPlanner.plan(BrowserHibernationSetting(mode: .off), pressure: .critical,
                                           candidates: [Candidate(key: "a", hiddenFor: 100_000)])
        #expect(plan.due.isEmpty)
        #expect(plan.nextCheck == nil)
        #expect(plan.exemptions["a"] == .disabled)
    }

    @Test func timeThresholdsFollowTheMode() {
        let candidates = [Candidate(key: "old", hiddenFor: 61 * 60), Candidate(key: "new", hiddenFor: 5 * 60)]
        let moderate = HibernationPlanner.plan(.fallback, pressure: .normal, candidates: candidates)
        #expect(moderate.due == ["old"])
        #expect(moderate.nextCheck == Double(55 * 60))
        let aggressive = HibernationPlanner.plan(BrowserHibernationSetting(mode: .aggressive), pressure: .normal, candidates: candidates)
        #expect(aggressive.due == ["old"])
        #expect(aggressive.nextCheck == Double(5 * 60))
        let minutes = HibernationPlanner.plan(BrowserHibernationSetting(mode: .minutes(2)), pressure: .normal, candidates: candidates)
        #expect(minutes.due == ["old", "new"])
        #expect(minutes.nextCheck == nil)
    }

    @Test func memoryPressureBringsDeadlinesForward() {
        let candidates = [Candidate(key: "a", hiddenFor: 11 * 60), Candidate(key: "b", hiddenFor: 30)]
        #expect(HibernationPlanner.plan(.fallback, pressure: .warning, candidates: candidates).due == ["a"])
        #expect(HibernationPlanner.plan(BrowserHibernationSetting(mode: .aggressive), pressure: .warning, candidates: candidates).due == ["a", "b"])
        #expect(HibernationPlanner.plan(.fallback, pressure: .critical, candidates: candidates).due == ["a", "b"])
    }

    @Test func exemptPagesNeverHibernate() {
        let setting = BrowserHibernationSetting(mode: .minutes(1), exclusions: ["example.com"])
        let candidates = [
            Candidate(key: "pinned", hiddenFor: 999, isPinned: true),
            Candidate(key: "devtools", hiddenFor: 999, hasDevTools: true),
            Candidate(key: "camera", hiddenFor: 999, isCapturing: true),
            Candidate(key: "excluded", hiddenFor: 999, host: "www.example.com"),
            Candidate(key: "oldfork", hiddenFor: 999, canRestore: false),
            Candidate(key: "plain", hiddenFor: 999, host: "other.org"),
        ]
        let plan = HibernationPlanner.plan(setting, pressure: .critical, candidates: candidates)
        #expect(plan.due == ["plain"])
        #expect(plan.exemptions == ["pinned": .pinned, "devtools": .devTools, "camera": .capturing,
                                    "excluded": .excluded, "oldfork": .unsupported])
        var withPinned = setting
        withPinned.includesPinnedTabs = true
        #expect(HibernationPlanner.plan(withPinned, pressure: .normal, candidates: [candidates[0]]).due == ["pinned"])
    }
}
