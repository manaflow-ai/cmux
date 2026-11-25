import Testing
@testable import CmuxNextAgentPane

/// The chat's menu reads whether it is half of a pair from `pane.tabState {terminalSwitch: true}`, which it sends as
/// the chat loads and as its "..." opens. Other reads (a hover over the header tools, a turn's end) do not ask, so the
/// App does not walk every machine's agents for them.
@MainActor
struct AgentPaneTerminalSwitchStateTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test(arguments: [true, false])
    func theTabStateSaysWhetherATerminalRunsTheChat(pair: Bool) async {
        let model = AgentPaneModel(host: NoHost())
        model.header = AgentPaneHeaderHooks(run: { _, _ in }, tabState: { AgentPaneHeaderState() }, switchesToTerminal: { pair })
        let reply = await model.respond(to: AgentPaneRequest(body: ["method": "pane.tabState", "params": ["terminalSwitch": true]]))
        #expect((reply["value"] as? [String: Any])?["terminalSwitch"] as? Bool == pair)
    }

    @Test func aReadThatDoesNotAskWalksNothing() async {
        let model = AgentPaneModel(host: NoHost())
        var asked = 0
        model.header = AgentPaneHeaderHooks(run: { _, _ in }, tabState: { AgentPaneHeaderState() }, switchesToTerminal: { asked += 1; return true })
        let reply = await model.respond(to: AgentPaneRequest(body: ["method": "pane.tabState"]))
        #expect((reply["value"] as? [String: Any])?["terminalSwitch"] == nil)
        #expect(asked == 0)
    }
}
