import Testing
@testable import CmuxNextAgentPane

/// The chat's menu reads whether it is half of a pair from `pane.tabState` (its `terminalSwitch`), as the menu opens.
@MainActor
struct AgentPaneTerminalSwitchStateTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test(arguments: [true, false])
    func theTabStateSaysWhetherATerminalRunsTheChat(pair: Bool) async {
        let model = AgentPaneModel(host: NoHost())
        model.header = AgentPaneHeaderHooks(run: { _, _ in }, tabState: { AgentPaneHeaderState() }, switchesToTerminal: { pair })
        let reply = await model.respond(to: .tabState(refresh: false))
        let result = reply["value"] as? [String: Any]
        #expect(result?["terminalSwitch"] as? Bool == pair)
    }
}
