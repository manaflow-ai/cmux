#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextAgentPane
import Foundation

/// `debug.agent_pane {action: "mcp_connect_ask", server, reason?, scope?}` (DEBUG capture builds): opens a
/// real MCP connect card in this chat, as an agent's `connect_mcp_server` call does: the app's acpmux gets
/// `_acpmux/mcp_connect_request` for the chat's session on a local line, resolves and checks the server, and
/// the card waits for a person's click (`click` on `.acpmux-mcp-card` delivers a real one). Answers at once
/// with the chat's session; the ask itself waits on its own line until the card is answered or closes.
@MainActor
enum DebugAgentPaneMcpConnect {
    /// The card closes after 15 minutes; the line stays open a little longer so the daemon, not the line, ends it.
    static let lineDeadline: Duration = .seconds(16 * 60)

    static func ask(_ params: [String: JSONValue], pane: String, view: AgentPaneView, services: AppServices) async -> JSONValue {
        let server = params["server"]?.stringValue ?? ""
        guard !server.isEmpty else { return .object(["pane": .string(pane), "error": .string("server is required")]) }
        let state = try? await view.callPageScript(DebugAgentPane.script, arguments: ["fn": "chatState", "args": [Any]()])
        guard let text = state as? String,
              let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let session = object["sessionId"] as? String, !session.isEmpty else {
            return .object(["pane": .string(pane), "error": .string("the chat has no session yet; send a prompt first")])
        }
        guard let environment = await AcpmuxEnvironment.resolvedApp(build: services.environment.build, mock: services.environment.showcase) else {
            return .object(["pane": .string(pane), "error": .string("no acpmux for this app")])
        }
        let request: [String: Any] = [
            "sessionId": session, "server": server,
            "reason": params["reason"]?.stringValue ?? "", "scope": params["scope"]?.stringValue ?? "chat",
        ]
        // task-owner: one debug ask, which ends when its card is answered or closes (at most `lineDeadline`).
        Task { @MainActor in
            guard let line = await AcpmuxPersonLine.open(environment, deadline: lineDeadline) else { return }
            defer { line.close() }
            _ = await line.call("_acpmux/mcp_connect_request", request)
        }
        return .object(["pane": .string(pane), "session": .string(session), "asked": .bool(true)])
    }
}
#endif
