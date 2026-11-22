#if DEBUG
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import Testing

/// cx-nn3e P0b gap 2 (nxdog81): `debug.agent_pane new_chat` and `send_prompt` drove the chat with
/// no user gesture, so the relay refused a folder outside the pane's roots
/// (`transport.path_outside_roots`) before acpmux could ask the trust question, and automation
/// never saw what a person sees. The chat verbs act as the user, as the `click` verb already does;
/// measuring verbs do not.
@MainActor
@Suite struct DebugAgentPaneGestureTests {
    @Test(arguments: ["new_chat", "send_prompt", "select_session", "answer_permission", "pick_folder"])
    func aChatVerbActsAsTheUser(_ action: String) {
        let transport = AgentPaneTransport()
        #expect(!transport.gestures.debugState.available)
        DebugAgentPane.actAsUser(action, gestures: transport.gestures)
        #expect(transport.gestures.debugState.available, "\(action) left no gesture")
    }

    @Test(arguments: ["perf_stats", "fling", "seed_rows", "chat_state", "acp_log", "readiness"])
    func aMeasuringVerbLeavesNoGesture(_ action: String) {
        let transport = AgentPaneTransport()
        DebugAgentPane.actAsUser(action, gestures: transport.gestures)
        #expect(!transport.gestures.debugState.available, "\(action) recorded a gesture")
    }
}
#endif
