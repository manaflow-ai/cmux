import CmuxMobileModel
import Foundation
import Testing
@testable import CmuxMobileWorkspaces

/// Full verify 2026-10-19 D7 (T-TABS-08): the close question for a tab
/// running `python3` came 2.1-2.4 s after the tap, while the phone asked the
/// Mac's `process-info`. The grid now reads the programs when it opens, so a
/// close of a busy tab asks at once; a close with nothing known shows the
/// question as pending ("Checking…") when the Mac is slow, and closes on its
/// own if the Mac then says the shell is idle.
@Suite struct TabClosePromptPlanTests {
    let shell = WorkspaceTab(id: "t2", kind: .terminal, title: "e2e-t1")

    @Test func aKnownRunningProgramAsksAtOnce() {
        var cache = TabProgramCache()
        cache.record(tabID: "t2", programs: ["python3.14"], at: 10)
        let plan = TabClosePromptPlan(closing: [shell], cached: cache.programs(of: ["t2"], now: 12))
        #expect(plan.immediate == TabCloseGuard.Prompt(title: "Close \u{201C}e2e-t1\u{201D}?", message: "Still running: python3.14."))
    }

    @Test func aStaleOrUnknownTabWaitsForTheMac() {
        var cache = TabProgramCache()
        cache.record(tabID: "t2", programs: ["python3.14"], at: 10)
        #expect(cache.programs(of: ["t2"], now: 10 + TabProgramCache.maxAge + 0.1) == nil)
        #expect(cache.programs(of: ["t2", "t9"], now: 11) == nil)
        let plan = TabClosePromptPlan(closing: [shell], cached: nil)
        #expect(plan.immediate == nil)
        #expect(plan.pending.title == "Close \u{201C}e2e-t1\u{201D}?")
        #expect(plan.pending.message == TabClosePromptPlan.checkingMessage)
    }

    @Test func aKnownIdleShellStillAsksTheMacButNeverAtOnce() {
        // Idle a moment ago is no proof it is idle now: the Mac is asked.
        var cache = TabProgramCache()
        cache.record(tabID: "t2", programs: [], at: 10)
        #expect(cache.programs(of: ["t2"], now: 11) == [])
        #expect(TabClosePromptPlan(closing: [shell], cached: []).immediate == nil)
    }

    @Test func theMacsReplyDecides() {
        let plan = TabClosePromptPlan(closing: [shell], cached: nil)
        #expect(plan.afterReply(programs: ["sleep"]) == .ask(TabCloseGuard.Prompt(title: "Close \u{201C}e2e-t1\u{201D}?", message: "Still running: sleep.")))
        #expect(plan.afterReply(programs: []) == .close)
        // Asked at once from the cache: an idle reply keeps the question (it is
        // safe to ask; a running program the cache missed is never closed unasked).
        let asked = TabClosePromptPlan(closing: [shell], cached: ["python3.14"])
        #expect(asked.afterReply(programs: []) == .ask(asked.immediate!))
    }

    @Test func theQuestionGoesPendingQuickly() {
        #expect(TabClosePromptPlan.pendingAfter <= .milliseconds(300))
    }
}
