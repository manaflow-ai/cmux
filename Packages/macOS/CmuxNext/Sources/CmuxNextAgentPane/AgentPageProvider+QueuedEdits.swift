import CmuxNextPages
import CmuxNextSettings

extension AgentPageProvider {
    /// Client draft storage only; these calls neither mutate nor resend a daemon prompt.
    static func queuedEdits(_ method: String, params: JSONValue, op: String) async throws -> JSONValue {
        guard let body = params.objectValue, let session = body["sessionId"]?.stringValue, !session.isEmpty else {
            throw PageError.invalidParams(op)
        }
        let store = AgentPaneDraftAttachments.shared?.queuedEdits
        if method == "chat.queuedEditDrafts.get" { return try await store?.read(session: session) ?? .object([:]) }
        guard let prompt = body["promptId"]?.stringValue, !prompt.isEmpty else { throw PageError.invalidParams(op) }
        if method == "chat.queuedEditDrafts.set", let value = body["draft"] {
            try await store?.set(session: session, prompt: prompt, value: value)
        } else if method == "chat.queuedEditDrafts.clear", let revision = body["revision"]?.stringValue {
            try await store?.clear(session: session, prompt: prompt, revision: revision)
        } else { throw PageError.invalidParams(op) }
        return .null
    }
}


extension AgentPaneBridge {
    static func queuedEditReply(_ method: String, params: JSONValue) async -> [String: Any] {
        do {
            let value = try await AgentPageProvider.queuedEdits(method, params: params, op: method)
            return AgentPaneReply.success(value.foundationObject)
        } catch {
            return AgentPaneReply.failure(code: "draft.storage_failed", message: "Could not save queued edit draft")
        }
    }
}
