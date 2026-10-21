import CmuxNextPages
import CmuxNextSettings
import Foundation

extension AgentPageProvider {
    /// `chat.draftAttachments` (`sessionId`, `attachments`) and `chat.draftAttachments.get`
    /// (`sessionId`): a chat's unsent chips in ``AgentPaneDraftAttachments/shared``. They are the
    /// chat's, not the pane's, so the model never sees these. The chips are decoded and encoded off
    /// the main actor: a composer of screenshots is tens of megabytes of base64.
    static func draftAttachments(_ method: String, params: JSONValue, op: String) async throws -> JSONValue {
        guard case .object(let body) = params, case .string(let session)? = body["sessionId"], !session.isEmpty else {
            throw PageError.invalidParams(op)
        }
        guard let store = AgentPaneDraftAttachments.shared else { return method == "chat.draftAttachments.get" ? .array([]) : .null }
        if method == "chat.draftAttachments.get" {
            let kept = await store.attachments(for: session)
            return await Task.detached { (try? JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(kept))) ?? .array([]) }.value
        }
        guard let list = body["attachments"],
              let attachments = await Task.detached(operation: {
                  try? JSONDecoder().decode([AgentPaneWakeState.Attachment].self, from: JSONEncoder().encode(list))
              }).value else { throw PageError.invalidParams(op) }
        await store.keep(attachments, for: session)
        return .null
    }
}
