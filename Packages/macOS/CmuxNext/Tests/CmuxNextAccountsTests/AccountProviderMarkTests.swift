import CmuxAgentBrands
import CmuxNextCodeRouter
import Testing

/// Every provider the Accounts screen lists draws its brand mark (design/agent-icons, R79),
/// except the ones whose owners publish no usable mark; those keep their SF Symbol.
struct AccountProviderMarkTests {
    static let withoutMark: Set<AIProvider> = [.groq, .bedrock, .vertex]

    @Test func everyProviderHasAMarkOrIsAKnownException() {
        for provider in AIProvider.allCases {
            let brand = AgentBrandCatalog.brand(for: provider.rawValue)
            #expect((brand == nil) == Self.withoutMark.contains(provider), "\(provider.rawValue) -> \(String(describing: brand))")
        }
        #expect(AgentBrandCatalog.brand(for: AIProvider.codex.rawValue) == .openai)
        #expect(AgentBrandCatalog.brand(for: AIProvider.xai.rawValue) == .grok)
    }
}
