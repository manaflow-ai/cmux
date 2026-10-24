import CmuxNextPages
import CmuxNextSettings
import Foundation

extension AgentPageProvider {
    /// `chat.draftAttachments` (`sessionId`, `attachments`; answers `{held}`, the ids of the chips
    /// whose contents are kept) and `chat.draftAttachments.get` (`sessionId`): a chat's unsent chips
    /// in ``AgentPaneDraftAttachments/shared``. They are the chat's, not the pane's, so the model
    /// never sees these. The chips are decoded and encoded off the main actor, in the chat's queue
    /// (taken before this call first waits, so the page's writes land in order): a composer of
    /// screenshots is tens of megabytes of base64.
    static func draftAttachments(_ method: String, params: JSONValue, op: String) async throws -> JSONValue {
        guard case .object(let body) = params, case .string(let session)? = body["sessionId"], !session.isEmpty else {
            throw PageError.invalidParams(op)
        }
        let store = AgentPaneDraftAttachments.shared
        if method == "chat.draftAttachments.get" {
            guard let store else { return .array([]) }
            if body["ordered"] == .bool(true) {
                let draft = await store.draft(for: session)
                return await Task.detached { AgentPaneDraftAttachments.json(draft) }.value
            }
            let kept = await store.attachments(for: session)
            return await Task.detached { AgentPaneDraftAttachments.json(kept) }.value
        }
        if let value = body["draft"] {
            if let store, let held = await store.keepOrdered(value, for: session) {
                return .object(["held": .array(held.map(JSONValue.string))])
            }
            // With no store, preserve the old valid-draft response without decoding on the main
            // actor; malformed drafts fall through to the legacy attachment-list validation.
            if store == nil, await Task.detached { AgentPaneDraftAttachments.decodeDraft(value) != nil }.value {
                return .object(["held": .array([])])
            }
        }
        guard let list = body["attachments"], case .array = list else { throw PageError.invalidParams(op) }
        guard let store else { return .object(["held": .array([])]) }
        guard let held = await store.keep(list, for: session) else { throw PageError.invalidParams(op) }
        return .object(["held": .array(held.map(JSONValue.string))])
    }
}
