import CMUXAgentLaunch
import Testing

/// The Activity panel names the agent a reply goes to ("Send to Codex",
/// "Reply to Codex…"). It used to say Claude for every agent.
/// https://github.com/manaflow-ai/cmux/issues/49333
@Suite("WorkstreamSource display name")
struct WorkstreamSourceDisplayNameTests {
    @Test("Each source names its own agent")
    func eachSourceNamesItsOwnAgent() {
        #expect(WorkstreamSource.claude.displayName == "Claude")
        #expect(WorkstreamSource.codex.displayName == "Codex")
        #expect(WorkstreamSource.opencode.displayName == "OpenCode")
        #expect(WorkstreamSource.hermesAgent.displayName == "Hermes Agent")
        #expect(WorkstreamSource.codebuddy.displayName == "CodeBuddy")
    }

    @Test("Only the Claude source is called Claude")
    func onlyClaudeIsClaude() {
        for source in WorkstreamSource.allCases where source != .claude {
            #expect(!source.displayName.contains("Claude"), "\(source)")
            #expect(!source.displayName.isEmpty, "\(source)")
        }
    }
}
