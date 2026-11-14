import CmuxNextAgentIntegrations
@testable import CmuxNextOnboarding
import Foundation
import Testing

/// The report `cmux setup mcp` prints in a DEV build (the fixture a cmux-tui test checks against
/// the real CLI's output, `cmux_setup_mcp_report_matches_the_apps_fixture`) read the way the app
/// reads it: both agents get cmux's tools in this build's terminals, Claude Code still has an old
/// DEV entry, and the cmux Tools step's yes is neither failed nor "nothing added".
@MainActor @Suite(.serialized) struct AgentToolsCLIReportTests {
    static func fixture() throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/agent-tools/setup-mcp-terminals.json")
        return try Data(contentsOf: url)
    }

    @MainActor final class Source: AgentToolsSource {
        let agents: [AgentToolsAgent]
        var choice: AgentToolsChoice = .ask
        init(agents: [AgentToolsAgent]) { self.agents = agents }
        func agentToolsChoice() -> AgentToolsChoice { choice }
        func setAgentToolsChoice(_ choice: AgentToolsChoice) async -> Bool {
            self.choice = choice
            return true
        }
        func agentToolsAgents() async -> [AgentToolsAgent] { agents }
        func applyAgentTools(remove: Bool) async -> [AgentToolsAgent]? { agents }
    }

    @Test func theCLIsDevBuildReportReadsAsAgentsWithCmuxToolsInTerminals() async throws {
        let agents = try #require(AgentToolsAgent.agents(setupReport: try Self.fixture()))
        #expect(agents.map(\.id) == ["claude", "codex"])
        #expect(agents.map(\.state) == [.terminals, .terminals])
        #expect(agents.map(\.stale) == [true, false])

        let model = AgentToolsStepModel(source: Source(agents: agents))
        model.start()
        let deadline = ContinuousClock.now + .seconds(5)
        while !model.loaded, ContinuousClock.now < deadline { await Task.yield() }
        model.add()
        while model.applying || !model.answered, ContinuousClock.now < deadline { await Task.yield() }
        #expect(!model.failed)
        #expect(model.addedCount == 2)
    }
}
