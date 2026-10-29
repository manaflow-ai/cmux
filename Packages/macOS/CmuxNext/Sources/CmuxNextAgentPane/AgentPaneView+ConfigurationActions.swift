import Foundation

/// The live acpmux configuration operation exposed by the command palette and
/// the shared action catalog.
public nonisolated enum AgentPaneConfigurationOperation: String, Sendable {
    case model = "chat.model"
    case effort = "chat.effort"
    case mode = "chat.mode"

    var payloadKey: String {
        switch self {
        case .model: "modelId"
        // `chat.effort` resolves the harness-specific option id from the
        // current summary (effort, reasoning_effort or thought_level).
        case .effort: "effort"
        case .mode: "modeId"
        }
    }

    /// The page bridge payload. A live session id is included so a queued
    /// native action cannot apply after this pane has switched sessions.
    public func payload(value: String, sessionID: String?) -> [String: String] {
        var payload = [payloadKey: value]
        if let sessionID { payload["expectedSessionId"] = sessionID }
        return payload
    }
}

extension AgentPaneView {
    /// The daemon's harness/family for this pane's current session, used to
    /// scope model suggestions to the chat that the action will change.
    public var sessionHarness: String? {
        guard let session = model.sessionId else { return nil }
        return model.transport.sessions.harness(of: session)
    }

    /// Applies a model, effort/config option or mode through the page's own
    /// direct action bridge. This preserves the same typed daemon routes as a
    /// picker click while avoiding focus changes for CLI/MCP callers.
    @MainActor
    public func setConfiguration(_ operation: AgentPaneConfigurationOperation, value: String) async throws {
        let payload: [String: Any] = operation.payload(value: value, sessionID: model.sessionId)
            .reduce(into: [:]) { $0[$1.key] = $1.value }
        _ = try await callPageScript(
            """
            const fn = globalThis.cmuxAcpmuxActions?.[action];
            if (typeof fn !== "function") throw new Error('missing action');
            const result = await fn(payload);
            if (result === false) throw new Error('refused');
            return true;
            """,
            arguments: [
                "action": operation.rawValue,
                "payload": payload,
            ])
    }
}
