import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeups
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
        // The page shows the draft it reads back, and waits for each write's answer.
        let shown = WorkPriority.userVisible.taskPriority
        if method == "chat.draftAttachments.get" {
            let ordered = body["ordered"] == .bool(true)
            // An ordered reader decodes `{text, attachments}` even when no chat keeps anything here.
            guard let store else { return ordered ? AgentPaneDraftAttachments.json(AgentPaneDraft()) : .array([]) }
            if ordered {
                let draft = await store.draft(for: session)
                return await Task.detached(priority: shown) { AgentPaneDraftAttachments.json(draft) }.value
            }
            let kept = await store.attachments(for: session)
            return await Task.detached(priority: shown) { AgentPaneDraftAttachments.json(kept) }.value
        }
        if let value = body["draft"] {
            if let store, let held = await store.keepOrdered(value, for: session) {
                return .object(["held": .array(held.map(JSONValue.string))])
            }
            // A present draft is an explicit ordered write. A malformed one must not fall through
            // to the legacy list path, which could erase an existing ordered draft.
            if store == nil {
                let valid = await Task.detached(priority: shown) { AgentPaneDraftAttachments.decodeDraft(value) != nil }
                if await valid.value { return .object(["held": .array([])]) }
            }
            throw PageError.invalidParams(op)
        }
        guard let list = body["attachments"], case .array = list else { throw PageError.invalidParams(op) }
        guard let store else { return .object(["held": .array([])]) }
        guard let held = await store.keep(list, for: session) else { throw PageError.invalidParams(op) }
        return .object(["held": .array(held.map(JSONValue.string))])
    }
}
