import CmuxAgentChat
import Foundation
import Testing

@testable import CmuxMobileShellUI

@Suite struct AgentUsageContextPresentationTests {
    @Test func contextAndTightestAllowanceAreShownTogether() {
        let reset = Date(timeIntervalSince1970: 10_000 + 7_200)
        let totals = ChatUsageTotals(
            usage: ChatTokenUsage(outputTokens: 12_345),
            contextTokens: 80_000,
            contextWindowTokens: 200_000,
            rateLimit: ChatUsageRateLimit(
                primary: .init(usedPercent: 42, resetsAt: reset.addingTimeInterval(3_600)),
                secondary: .init(usedPercent: 91, resetsAt: reset)
            )
        )

        let presentation = AgentUsageContextPresentation(
            totals: totals,
            now: Date(timeIntervalSince1970: 10_000)
        )

        #expect(presentation.labels == ["40% context", "12.3K tokens", "91% allowance", "Resets in 2h"])
        #expect(presentation.isNearLimit)
        #expect(presentation.systemImage == "exclamationmark.triangle.fill")
    }

    @Test func missingTightestWindowResetDoesNotBorrowAnotherWindowsReset() {
        let totals = ChatUsageTotals(rateLimit: ChatUsageRateLimit(
            primary: .init(usedPercent: 42, resetsAt: Date(timeIntervalSince1970: 20_000)),
            secondary: .init(usedPercent: 91)
        ))

        let presentation = AgentUsageContextPresentation(
            totals: totals,
            now: Date(timeIntervalSince1970: 10_000)
        )

        #expect(presentation.labels == ["91% allowance"])
    }

    @Test func missingProviderValuesStayHonest() {
        let presentation = AgentUsageContextPresentation(
            totals: ChatUsageTotals(),
            now: Date(timeIntervalSince1970: 10_000)
        )

        #expect(presentation.labels == ["Usage unavailable"])
        #expect(!presentation.isNearLimit)
        #expect(presentation.accessibilityLabel.contains("Usage unavailable"))
    }

    @Test func spendControlTakesPrecedenceOverWindowNumbers() {
        let totals = ChatUsageTotals(
            rateLimit: ChatUsageRateLimit(
                primary: .init(usedPercent: 15),
                spendControlReached: true
            )
        )

        let presentation = AgentUsageContextPresentation(totals: totals)

        #expect(presentation.labels == ["Limit reached"])
        #expect(presentation.isNearLimit)
    }
}
