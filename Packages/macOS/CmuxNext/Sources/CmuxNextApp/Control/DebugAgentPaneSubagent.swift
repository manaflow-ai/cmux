#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextAgentPane
import CmuxNextSettings

/// `debug.agent_pane {action: "open_subagent", index, focus}` (DEBUG builds): opens the pane of the
/// `subagents` fixture's subagent at `index` (from 1, in the fixture's order: the reviewer, the
/// auditor, then helper 1, 2, ...; webviews subagentsFixture.ts) through the hook a tray line's
/// `chat.subagentPane` calls (``AgentPaneHeaderHooks/openSubagent``: AgentTabStore's openSubagent,
/// then ``AgentSubagentPanes`` and openBeside place it), so a capture records where real opens land.
/// `focus` (false by default) is the request's: unfocused, the chat keeps focus. The chat request
/// needs the model's session, which a showcase chat never has: its page skips `chat.persistSession`
/// for the mock daemon's session (App.tsx persistSession). The page's own session stands in then, as
/// a subagent's pane is a tab on the chat's own session.
@MainActor
enum DebugAgentPaneSubagent {
    /// The most subagents the fixture starts (SUBAGENT_FIXTURE_MAX).
    static let fixtureMax = 8

    /// The page's session, as `chat_state` reports it.
    static let pageSessionScript = "return window.cmuxAcpmuxDebug?.chatState?.()?.sessionId ?? null;"

    /// The id of the fixture's subagent at `index` (from 1); nil past the fixture's.
    static func fixtureAgent(_ index: Int) -> String? {
        switch index {
        case 1: "fixture-reviewer"
        case 2: "fixture-auditor"
        case 3...fixtureMax: "fixture-helper-\(index - 2)"
        default: nil
        }
    }

    /// Opens the subagent's pane for the chat `model` shows in `pane`; `pageSession` reads the page's
    /// session when the model has none.
    static func open(_ params: [String: JSONValue], pane: String, model: AgentPaneModel,
                     pageSession: @MainActor () async -> String?) async -> JSONValue {
        guard let index = params["index"]?.intValue, let agent = fixtureAgent(index) else {
            return .object(["pane": .string(pane), "error": .string("index must be 1 to \(fixtureMax), a subagent of the subagents fixture")])
        }
        guard let header = model.header else { return .object(["pane": .string(pane), "error": .string("the chat has no header hooks")]) }
        var session = model.sessionId
        if session == nil { session = await pageSession() }
        guard let session, !session.isEmpty else {
            return .object(["pane": .string(pane), "error": .string("the chat has no session yet; send_prompt first")])
        }
        guard header.openSubagent(session, agent, params["focus"]?.boolValue == true) else {
            return .object(["pane": .string(pane), "agent": .string(agent), "opened": .bool(false), "error": .string("the app opened no pane for \(agent)")])
        }
        return .object(["pane": .string(pane), "opened": .bool(true), "agent": .string(agent)])
    }
}
#endif
