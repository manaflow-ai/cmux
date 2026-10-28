import Foundation
import CmuxNextPages

extension AgentPageProvider {
    static func draftText(_ method: String, params: JSONValue, op: String) async throws -> JSONValue {
        guard case .object(let body) = params,
              case .string(let session)? = body["sessionId"], !session.isEmpty else {
            throw PageError.invalidParams(op)
        }
        let store = AgentPaneDraftAttachments.shared?.draftTexts
        if method == "chat.draftText.get" {
            let text = try await store?.get(session)
            return text.map(JSONValue.string) ?? .null
        }
        guard method == "chat.draftText.set", case .string(let text)? = body["text"] else {
            throw PageError.invalidParams(op)
        }
        try await store?.set(text, for: session)
        return .object([:])
    }
}
