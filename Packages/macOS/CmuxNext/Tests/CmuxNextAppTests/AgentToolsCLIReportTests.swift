import CmuxNextAgentIntegrations
import Foundation
import Testing

/// The report `cmux setup mcp` prints (the fixture a cmux-tui test checks against the real CLI's
/// output, `cmux_setup_mcp_report_matches_the_apps_fixture`) read the way the app reads it: both
/// agents get cmux's tools in cmux.
@MainActor @Suite(.serialized) struct AgentToolsCLIReportTests {
    static func fixture() throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/agent-tools/setup-mcp-terminals.json")
        return try Data(contentsOf: url)
    }

    @Test func theCLIsReportReadsAsAgentsWithCmuxToolsInCmux() async throws {
        let agents = try #require(AgentToolsAgent.agents(setupReport: try Self.fixture()))
        #expect(agents.map(\.id) == ["claude", "codex"])
        #expect(agents.map(\.state) == [.terminals, .terminals])
        #expect(AgentToolsAgent.manualCommands(setupReport: try Self.fixture()).isEmpty, "the fixture keeps only their count")
    }
}
