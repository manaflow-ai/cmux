import CmuxNextPages
import CmuxNextSettings
import Foundation

extension AgentPageProvider {
    /// `chat.draftAttachments` (`sessionId`, `attachments`; answers `{held}`, the ids of the chips
    /// whose contents are kept) and `chat.draftAttachments.get` (`sessionId`): a chat's unsent chips
    /// in ``AgentPaneDraftAttachments/shared``. They are the chat's, not the pane's, so the model
    /// never sees these. The chips are decoded and encoded off the main actor, in the chat's queue
    /// (taken before this call first waits, so the page's writes land in order): a composer of
    /// screenshots is tens of megabytes of base64. RFD 0138: the write's optional `draftId` names the
    /// acpmux draft the chips' images are kept under; a get with `withDraftId` answers
    /// `{attachments, draftId?}` instead of the bare list an older page reads.
    static func draftAttachments(_ method: String, params: JSONValue, op: String) async throws -> JSONValue {
        guard case .object(let body) = params, case .string(let session)? = body["sessionId"], !session.isEmpty else {
            throw PageError.invalidParams(op)
        }
        let store = AgentPaneDraftAttachments.shared
        if method == "chat.draftAttachments.get" {
            let withDraftId = body["withDraftId"] == .bool(true)
            guard let store else { return withDraftId ? .object(["attachments": .array([])]) : .array([]) }
            let kept = await store.draft(for: session)
            let attachments = kept.attachments
            let list = await Task.detached { AgentPaneDraftAttachments.json(attachments) }.value
            guard withDraftId else { return list }
            guard let draftId = kept.draftId else { return .object(["attachments": list]) }
            return .object(["attachments": list, "draftId": .string(draftId)])
        }
        guard let list = body["attachments"], case .array = list else { throw PageError.invalidParams(op) }
        // A draft id is a surface id in acpmux: one line of at most 64 characters.
        var draftId: String?
        switch body["draftId"] {
        case nil, .null?: draftId = nil
        case .string(let id)? where !id.isEmpty && id.count <= 64 && !id.contains(where: \.isNewline):
            draftId = id
        default: throw PageError.invalidParams(op)
        }
        guard let store else { return .object(["held": .array([])]) }
        guard let held = await store.keep(list, draftId: draftId, for: session) else { throw PageError.invalidParams(op) }
        return .object(["held": .array(held.map(JSONValue.string))])
    }
}
