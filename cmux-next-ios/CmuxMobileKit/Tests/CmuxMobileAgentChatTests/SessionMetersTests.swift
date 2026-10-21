@testable import CmuxMobileAgentChat
import Testing

@Suite struct SessionMetersTests {
    @Test func usageMapsToFractionAndLabels() {
        let usage = ContextUsage(used: 48_000, size: 200_000)
        #expect(usage.percent == 24)
        #expect(usage.tokensLabel == "48K of 200K tokens")
        #expect(!usage.isNearlyFull)
        #expect(ContextUsage(used: 170_000, size: 200_000).isNearlyFull)
        #expect(ContextUsage(used: 5, size: 0).fraction == 0)
        #expect(ContextUsage(used: 300, size: 100).fraction == 1)
        #expect(ContextUsage.compact(1_500) == "1.5K")
        #expect(ContextUsage.compact(1_000_000) == "1M")
    }

    @Test func planProgressCountsAndPicksTheCurrentStep() throws {
        let entries = [
            ACPPlanEntry(content: "Read", status: .completed),
            ACPPlanEntry(content: "Edit", status: .completed),
            ACPPlanEntry(content: "Test", status: .inProgress),
            ACPPlanEntry(content: "Ship", status: .pending),
        ]
        let progress = try #require(PlanProgress(entries: entries))
        #expect(progress.countLabel == "2 / 4")
        #expect(progress.current == "Test")
        #expect(!progress.isDone)
        let pendingOnly = try #require(PlanProgress(entries: [ACPPlanEntry(content: "A", status: .completed), ACPPlanEntry(content: "B")]))
        #expect(pendingOnly.current == "B")
        #expect(PlanProgress(entries: []) == nil)
    }
}
