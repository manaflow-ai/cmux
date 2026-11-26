import Foundation
import Testing

@testable import CmuxAgentChat

@Suite("AgentModelCatalog")
struct AgentModelCatalogTests {
    private let catalog = AgentModelCatalog()

    @Test(arguments: [
        ("claude-opus-4-8", "Opus 4.8", 1_000_000),
        ("claude-opus-5-5", "Opus 5.5", 1_000_000),
        ("claude-haiku-4-5-20251001", "Haiku 4.5", 200_000),
        ("claude-haiku-4-5@20251001", "Haiku 4.5", 200_000),
        ("claude-sonnet-4-5-20250929", "Sonnet 4.5", 200_000),
        ("claude-sonnet-4-5-20250929[1m]", "Sonnet 4.5", 1_000_000),
        ("us.anthropic.claude-opus-4-1-20250805-v1:0", "Opus 4.1", 200_000),
    ])
    func claudeIDsNormalize(modelID: String, displayName: String, window: Int) throws {
        let info = try #require(catalog.info(forModelID: modelID))
        #expect(info.displayName == displayName)
        #expect(info.contextWindow == window)
        #expect(info.pricing != nil)
    }

    @Test func familyPrefixesDoNotBorrowAnotherModelsPrice() throws {
        let opus4 = try #require(catalog.info(forModelID: "claude-opus-4-20250514")?.pricing)
        let opus48 = try #require(catalog.info(forModelID: "claude-opus-4-8")?.pricing)
        #expect(opus4.inputPerMTok == 15)
        #expect(opus48.inputPerMTok == 5)
    }

    /// A legacy id carries its version before its family name, and it is not
    /// in the price table. It still has to read as a model name: the sidebar
    /// appends the name to a status line that truncates at the tail, so a raw
    /// id would push the context percentage and the cost out of the row.
    @Test(arguments: [
        ("claude-3-5-sonnet-20241022", "Sonnet 3.5"),
        ("claude-3-7-sonnet-20250219", "Sonnet 3.7"),
        ("us.anthropic.claude-3-7-sonnet-20250219-v1:0", "Sonnet 3.7"),
        ("claude-3-opus-20240229", "Opus 3"),
        ("claude-3-haiku-20240307", "Haiku 3"),
    ])
    func legacyIDsReadAsAModelName(modelID: String, displayName: String) throws {
        let legacy = try #require(catalog.info(forModelID: modelID))
        #expect(legacy.displayName == displayName)
        #expect(legacy.pricing == nil)
    }

    @Test func nonClaudeIDsAreUnpriced() throws {
        let codex = try #require(catalog.info(forModelID: "gpt-5-codex", reportedContextWindow: 272_000))
        #expect(codex.pricing == nil)
        #expect(codex.contextWindow == 272_000)
        #expect(catalog.info(forModelID: "gpt-6-astra")?.contextWindow == nil)
        #expect(catalog.info(forModelID: "  ") == nil)
    }

    @Test func pricingMathUsesPerMillionRates() {
        let pricing = AgentModelPricing(
            inputPerMTok: 3, outputPerMTok: 15, cacheWrite5mPerMTok: 3.75, cacheWrite1hPerMTok: 6, cacheReadPerMTok: 0.3
        )
        let tokens = AgentUsageTokenCounts(
            uncachedInput: 1_000_000, cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000, cacheRead: 1_000_000, output: 1_000_000
        )
        #expect(abs(pricing.estimatedCostUSD(for: tokens) - 28.05) < 1e-9)
        #expect(pricing.estimatedCostUSD(for: .zero) == 0)
    }

    @Test func costCombinationPropagatesUnknownAndLowerBound() {
        let exact = AgentUsageCost(usd: 1, isLowerBound: false)
        let partial = AgentUsageCost(usd: 2, isLowerBound: true)
        #expect(AgentUsageCost.combine(exact, partial) == AgentUsageCost(usd: 3, isLowerBound: true))
        #expect(AgentUsageCost.combine(exact, nil) == nil)
        #expect(AgentUsageCost(usd: 0, isLowerBound: true, hasPricedUsage: false).displayable == nil)
    }

    @Test func snapshotFractionClampsAndHandlesUnknownWindow() {
        let over = AgentUsageSnapshot(modelID: "m", modelDisplayName: "m", contextTokens: 300, contextWindow: 200, estimatedCost: nil)
        #expect(over.contextFraction == 1)
        let unknown = AgentUsageSnapshot(modelID: "m", modelDisplayName: "m", contextTokens: 300, contextWindow: nil, estimatedCost: nil)
        #expect(unknown.contextFraction == nil)
    }
}
