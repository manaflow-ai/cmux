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
        #expect(seeds.map(\.command) == [
            "claude -- \"$CMUX_TASK_PROMPT\"",
            "codex -- \"$CMUX_TASK_PROMPT\"",
            "opencode --prompt \"$CMUX_TASK_PROMPT\"",
            "",
        ])
        #expect(seeds.allSatisfy { $0.defaultDirectory == nil })
    }

    @Test func onlyWhitespaceCommandsArePlainShells() {
        #expect(MobileTaskTemplate(name: "Shell", icon: "terminal", command: "").isPlainShell)
        #expect(MobileTaskTemplate(name: "Shell", icon: "terminal", command: " \n\t ").isPlainShell)
        #expect(!MobileTaskTemplate(name: "Comment", icon: "terminal", command: "# note").isPlainShell)
        #expect(!MobileTaskTemplate(name: "Assignment", icon: "terminal", command: "FOO=bar").isPlainShell)
        #expect(!MobileTaskTemplate(name: "Redirect", icon: "terminal", command: "2>&1").isPlainShell)
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
