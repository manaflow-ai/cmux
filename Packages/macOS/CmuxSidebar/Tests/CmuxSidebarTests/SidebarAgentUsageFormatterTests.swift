import CmuxSidebar
import Foundation
import Testing

@Suite("SidebarAgentUsageFormatter")
struct SidebarAgentUsageFormatterTests {
    /// Marks unlike the app's, so each assertion shows which one was used.
    private static let strings = SidebarAgentUsageFormatter.Strings(
        estimatedCost: { "≈\($0)" },
        estimatedCostAtLeast: { "≥\($0)" },
        costHelpText: "List-price estimate"
    )
    private static let usage = SidebarAgentUsage(modelName: "Opus 4.8", contextFraction: 0.4213, estimatedCostUSD: 1.2)

    private static func formatter(_ parts: SidebarAgentUsage.Parts = .all) -> SidebarAgentUsageFormatter {
        SidebarAgentUsageFormatter(strings: strings, locale: Locale(identifier: "en_US"), shownParts: parts)
    }

    @Test func summaryMarksTheCostWithTheSuppliedStrings() {
        #expect(Self.formatter().summary(for: Self.usage) == "Opus 4.8 · 42% · ≈$1.20")
        let partial = SidebarAgentUsage(modelName: "Opus 4.8", contextFraction: nil, estimatedCostUSD: 1.2, costIsLowerBound: true)
        #expect(Self.formatter().summary(for: partial) == "Opus 4.8 · ≥$1.20")
    }

    @Test func eachPartDropsOnlyItsComponent() {
        // A reporter tooltip, so dropping the cost must visibly keep it.
        let claude = SidebarStatusEntry(key: "claude_code", value: "Running", timestamp: Date(timeIntervalSince1970: 10), helpText: "Reporter tooltip")
        func shown(_ parts: SidebarAgentUsage.Parts) -> SidebarStatusEntry {
            Self.formatter(parts).decorate([claude], usageByStatusKey: ["claude_code": Self.usage])[0]
        }

        #expect(shown([.context, .cost]).value == "Running · 42% · ≈$1.20")
        #expect(shown([.model, .cost]).value == "Running · Opus 4.8 · ≈$1.20")
        #expect(shown([.model, .context]).value == "Running · Opus 4.8 · 42%")
        #expect(shown([.model, .context]).helpText == "Reporter tooltip")
        #expect(shown([.cost]).helpText == "List-price estimate")
        #expect(shown([]) == claude)
    }

    @Test func anEntryWithNothingToShowIsLeftUnchanged() {
        let claude = SidebarStatusEntry(key: "claude_code", value: "Running", timestamp: Date(timeIntervalSince1970: 10))
        let unpriced = SidebarAgentUsage(modelName: "gpt-6-astra", contextFraction: nil, estimatedCostUSD: nil)

        #expect(Self.formatter([.context, .cost]).decorate([claude], usageByStatusKey: ["claude_code": unpriced]) == [claude])
        #expect(Self.formatter().decorate([claude], usageByStatusKey: [:]) == [claude])
    }

    @Test func decorationKeepsEveryOtherField() {
        let claude = SidebarStatusEntry(
            key: "claude_code",
            value: "Running",
            icon: "bolt.fill",
            color: "#4C8DFF",
            url: URL(string: "https://example.com/run"),
            priority: 5,
            format: .markdown,
            timestamp: Date(timeIntervalSince1970: 10),
            helpText: "Reporter tooltip",
            workState: .subagents
        )
        let other = SidebarStatusEntry(key: "build", value: "Passing", timestamp: Date(timeIntervalSince1970: 10))

        let decorated = Self.formatter().decorate([claude, other], usageByStatusKey: ["claude_code": Self.usage])

        #expect(decorated == [
            SidebarStatusEntry(
                key: "claude_code",
                value: "Running · Opus 4.8 · 42% · ≈$1.20",
                icon: "bolt.fill",
                color: "#4C8DFF",
                url: URL(string: "https://example.com/run"),
                priority: 5,
                format: .markdown,
                timestamp: Date(timeIntervalSince1970: 10),
                helpText: "List-price estimate",
                workState: .subagents
            ),
            other,
        ])
    }
}
