import Testing
@testable import CmuxNextActions

@Suite
struct AgentConfigurationActionCatalogTests {
    private static let expected: [(ActionID, String, String)] = [
        ("agentPane.setModel", "model", "agentModels"),
        ("agentPane.setEffort", "effort", "agentEfforts"),
        ("agentPane.setMode", "mode", "agentModes"),
    ]

    @Test("each setter is palette, CLI and MCP reachable")
    func surfacesAndArguments() throws {
        for (id, argument, source) in Self.expected {
            let descriptor = try #require(AgentConfigurationActionCatalog.descriptors().first { $0.id == id })
            #expect(descriptor.surfacePlan.palette.isOffered)
            #expect(descriptor.surfacePlan.cli?.isOffered == true)
            #expect(descriptor.surfacePlan.mcp?.isOffered == true)
            #expect(descriptor.arguments.map(\.name) == [argument])
            #expect(descriptor.arguments.first?.suggestions?.source == source)
            #expect(descriptor.requires.contains(.agentPaneFocused))
            #expect(descriptor.targets == [.pane, .tab, .agentChat])
        }
    }

    @Test("palette keywords expose the three configuration verbs")
    func keywords() throws {
        let byID = Dictionary(uniqueKeysWithValues: AgentConfigurationActionCatalog.descriptors().map { ($0.id, Set($0.keywords)) })
        #expect(byID["agentPane.setModel"]?.isSuperset(of: ["model", "switch", "set"]) == true)
        #expect(byID["agentPane.setEffort"]?.isSuperset(of: ["effort", "reasoning", "set"]) == true)
        #expect(byID["agentPane.setMode"]?.isSuperset(of: ["mode", "permission", "set"]) == true)
    }
}
