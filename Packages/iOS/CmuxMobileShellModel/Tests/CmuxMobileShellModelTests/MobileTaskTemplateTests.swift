import Foundation
import Testing
@testable import CmuxMobileShellModel

@Suite struct MobileTaskTemplateTests {
    @Test func seedDefaultsUseExpectedNamesIconsAndCommands() {
        let seeds = MobileTaskTemplate.seedDefaults(
            claudeName: "Claude",
            codexName: "Codex",
            openCodeName: "OpenCode",
            shellName: "Shell"
        )

        #expect(seeds.map(\.name) == ["Claude", "Codex", "OpenCode", "Shell"])
        #expect(seeds.map(\.icon) == ["agent:claude", "agent:codex", "agent:opencode", "terminal"])
        #expect(seeds.map(\.command) == ["claude", "codex", "opencode", ""])
        #expect(seeds.allSatisfy { $0.defaultDirectory == nil })
    }

    @Test func agentIconAssetNamesResolveOnlyKnownAgents() {
        #expect(MobileTaskTemplate.agentIconAssetName(for: "agent:claude") == "Claude")
        #expect(MobileTaskTemplate.agentIconAssetName(for: "agent:codex") == "Codex")
        #expect(MobileTaskTemplate.agentIconAssetName(for: "agent:opencode") == "OpenCode")
        #expect(MobileTaskTemplate.agentIconAssetName(for: "agent:unknown") == nil)
        #expect(MobileTaskTemplate.agentIconAssetName(for: "terminal") == nil)
        #expect(MobileTaskTemplate.agentIconAssetName(for: "🚀") == nil)
    }

    @Test func templateCodableRoundTripsEditableFields() throws {
        let id = UUID()
        let template = MobileTaskTemplate(
            id: id,
            name: "Build",
            icon: "hammer",
            command: "swift test",
            defaultDirectory: "~/code/cmux"
        )

        let data = try JSONEncoder().encode(template)
        let decoded = try JSONDecoder().decode(MobileTaskTemplate.self, from: data)

        #expect(decoded == template)
    }
}
