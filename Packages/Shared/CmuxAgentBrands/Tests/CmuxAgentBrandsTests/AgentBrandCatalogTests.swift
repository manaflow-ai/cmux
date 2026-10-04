import CoreGraphics
import Testing
@testable import CmuxAgentBrands

@Suite struct AgentBrandCatalogTests {
    @Test func sharedResolutionCasesResolve() {
        for (input, expected) in AgentBrandCatalog.resolutionCases {
            #expect(AgentBrandCatalog.brand(for: input) == expected, "\(input.debugDescription)")
        }
    }

    @Test func everySupportedAgentResolvesToItsBrand() {
        #expect(!AgentBrandCatalog.agents.isEmpty)
        for agent in AgentBrandCatalog.agents {
            #expect(AgentBrandCatalog.brand(for: agent.id) == agent.brand, "\(agent.id)")
            #expect(AgentBrandCatalog.brand(for: agent.id.uppercased()) == agent.brand, "\(agent.id) uppercased")
            if let brand = agent.brand {
                #expect(AgentBrandCatalog.spec(for: brand) != nil, "\(agent.id) has no mark")
            }
        }
    }

    @Test func requestedHarnessesHaveMarks() {
        // R79: Claude Code, Codex/ChatGPT, OpenCode, Pi, Hermes and the DeepSeek harness.
        for agent in ["claude", "codex", "chatgpt", "opencode", "pi", "hermes-agent", "dsh", "deepseek"] {
            #expect(AgentBrandCatalog.spec(forAgent: agent) != nil, "\(agent)")
        }
    }

    @Test func everyMarkParsesIntoItsViewBox() throws {
        #expect(AgentBrandID.allCases.count >= 20)
        for brand in AgentBrandID.allCases {
            let spec = try #require(AgentBrandCatalog.spec(for: brand), "\(brand)")
            let box = CGRect(x: spec.viewBox.x, y: spec.viewBox.y, width: spec.viewBox.width, height: spec.viewBox.height)
            var union = CGRect.null
            for item in spec.paths {
                let path = try #require(AgentBrandRenderer.path(item.d), "\(brand) path does not parse")
                union = union.union(path.boundingBoxOfPath)
            }
            // The artwork fills most of its view box. It may run past an edge where the owner's
            // framing crops it (Hermes Agent's portrait), but never sits in another coordinate space.
            let shown = union.intersection(box)
            #expect(!shown.isNull && shown.width * shown.height >= box.width * box.height * 0.4, "\(brand) art \(union) vs view box \(box)")
        }
    }

    @Test func parserRejectsMalformedData() {
        #expect(AgentBrandRenderer.path("") == nil)
        #expect(AgentBrandRenderer.path("M1 2L3") == nil)
        #expect(AgentBrandRenderer.path("M1 2Q3 4 5 6") == nil)
        #expect(AgentBrandRenderer.path("M0 0L-1.5 2e1Z") != nil)
    }
}
