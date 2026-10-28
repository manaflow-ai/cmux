import Foundation
import CmuxNextPages

extension AgentPageProvider {
    static func draftText(_ method: String, params: JSONValue, op: String) throws -> JSONValue {
        guard case .object(let body) = params,
              case .string(let session)? = body["sessionId"], !session.isEmpty else {
            throw PageError.invalidParams(op)
        }
        let store = AgentPaneDraftTexts.shared
        if method == "chat.draftText.get" { return store?.get(session).map(JSONValue.string) ?? .null }
        guard method == "chat.draftText.set", case .string(let text)? = body["text"] else {
            throw PageError.invalidParams(op)
        }
        store?.set(text, for: session)
        return .object([:])
    }
}
