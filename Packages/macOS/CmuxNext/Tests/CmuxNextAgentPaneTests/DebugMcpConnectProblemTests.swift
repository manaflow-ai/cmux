#if DEBUG || CMUX_BENCH_HOOKS
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The capture step that reads the debug MCP connect asks (`debug.agent_pane mcp_connect_ask
/// read: true`) fails when no ask succeeded: no answer, an empty answer (acpmux refused the call)
/// or an `error`. Only replies that all carry a `status` pass.
@Suite struct DebugMcpConnectProblemTests {
    @Test func noAnswerIsAProblem() {
        #expect(AgentPaneView.debugMcpConnectProblem([:]) != nil)
    }

    @Test func aRefusedOrFailedAskIsAProblem() {
        #expect(AgentPaneView.debugMcpConnectProblem(["s1": [String: Any]()]) != nil)
        #expect(AgentPaneView.debugMcpConnectProblem(["s1": ["error": "no session"]]) != nil)
        #expect(AgentPaneView.debugMcpConnectProblem(["s1": ["name": "deepwiki"]]) != nil)
    }

    @Test func answeredAsksPass() {
        #expect(AgentPaneView.debugMcpConnectProblem(["s1": ["status": "approved", "connect": "connected"]]) == nil)
        #expect(AgentPaneView.debugMcpConnectProblem(["s1": ["status": "declined"]]) == nil)
    }
}
#endif
