#if DEBUG || CMUX_BENCH_HOOKS
import Foundation

extension AgentPaneView {
    /// DEBUG capture builds (`debug.agent_pane {action: "mcp_connect_ask"}`): opens a real MCP connect card
    /// in this chat, as an agent's `connect_mcp_server` call does. `environment`'s acpmux gets
    /// `_acpmux/mcp_connect_request` for the chat's session on a local line, resolves and checks the
    /// server, and the card waits for a person's click. Answers at once with the session; the ask waits on
    /// its own line until the card is answered or closes (16 minutes at most, past the card's 15).
    ///
    /// - Parameters:
    ///   - server: A known name, an https URL or a command line, as the agent's tool takes it.
    ///   - reason: The sentence the card shows.
    ///   - scope: The proposed scope.
    ///   - environment: The acpmux this app's chats use.
    /// - Returns: `{session, asked}`, or `{error}` when the chat has no session yet.
    public func debugMcpConnectAsk(server: String, reason: String, scope: String,
                                   environment: AcpmuxEnvironment?) async -> [String: Any] {
        guard !server.isEmpty else { return ["error": "server is required"] }
        let state = try? await callPageScript(Self.debugChatStateScript)
        guard let text = state as? String,
              let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let session = object["sessionId"] as? String, !session.isEmpty else {
            return ["error": "the chat has no session yet; send a prompt first"]
        }
        guard let environment else { return ["error": "no acpmux for this app"] }
        let request: [String: Any] = ["sessionId": session, "server": server, "reason": reason, "scope": scope]
        // task-owner: one debug ask, which ends when its card is answered or closes (16 minutes at most).
        Task { @MainActor [weak self] in
            guard let line = await AcpmuxPersonLine.open(environment, deadline: .seconds(16 * 60)) else { return }
            defer { line.close() }
            let reply = await line.call("_acpmux/mcp_connect_request", request)
            self?.debugMcpConnectReplies[session] = reply ?? [:]
        }
        return ["session": session, "asked": true]
    }

    /// DEBUG capture actions of `debug.agent_pane` that run natively in this package: `set_files`
    /// (`selector`, `paths`) and `mcp_connect_ask` (`server`, `reason`, `scope`; `read: true`
    /// returns what the asks got back). The App forwards here so its control file does not grow.
    ///
    /// - Parameters:
    ///   - action: The `debug.agent_pane` action.
    ///   - params: The action's parameters as `JSONSerialization` objects.
    ///   - environment: Resolves the acpmux this app's chats use; called only for an ask.
    /// - Returns: The answer without `pane`, or nil when `action` is not one of these.
    public func debugNativeAction(_ action: String, params: [String: Any],
                                  environment: () async -> AcpmuxEnvironment?) async -> [String: Any]? {
        switch action {
        case "set_files":
            let error = await debugSetFiles(selector: params["selector"] as? String ?? ".acpmux-attach-input",
                                            paths: (params["paths"] as? [Any])?.compactMap { $0 as? String } ?? [])
            return ["error": error ?? NSNull()]
        case "mcp_connect_ask":
            // A failed ask answers `error`, so a capture step that drives it is marked failed, never
            // "ok" while no card opened.
            if params["read"] as? Bool == true {
                let replies = debugMcpConnectAnswers
                if let problem = Self.debugMcpConnectProblem(replies) { return ["error": problem, "replies": replies] }
                return ["replies": replies]
            }
            let asked = await debugMcpConnectAsk(server: params["server"] as? String ?? "",
                                                 reason: params["reason"] as? String ?? "",
                                                 scope: params["scope"] as? String ?? "chat",
                                                 environment: await environment())
            if let error = asked["error"] { return ["error": error] }
            return ["result": asked]
        default:
            return nil
        }
    }

    /// Why the debug asks' replies are not a success: none came back, acpmux refused one (an
    /// empty reply), or one says `error`; nil when every reply has a `status`.
    nonisolated static func debugMcpConnectProblem(_ replies: [String: Any]) -> String? {
        guard !replies.isEmpty else { return "no MCP connect ask got an answer yet" }
        for (session, reply) in replies {
            guard let reply = reply as? [String: Any], !reply.isEmpty else {
                return "acpmux refused the MCP connect ask of session \(session)"
            }
            if let error = reply["error"] { return "the MCP connect ask of session \(session) failed: \(error)" }
            if reply["status"] == nil { return "the MCP connect ask of session \(session) answered no status" }
        }
        return nil
    }

    /// What the debug asks of this pane got back, by session: such as `connect: signInNeeded` with its
    /// `signInUrl` for `escalate_auth`. Never a secret.
    public var debugMcpConnectAnswers: [String: Any] { debugMcpConnectReplies }

    private static let debugChatStateScript = """
        const debug = window.cmuxAcpmuxDebug;
        return debug && typeof debug.chatState === "function" ? JSON.stringify(debug.chatState()) : null;
        """
}
#endif
