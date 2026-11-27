import CmuxNextPages
import CmuxNextSettings
import Foundation

extension AgentPageProvider {
    static func tail(_ method: String, params: JSONValue, op: String, host: (any AgentPaneHostProviding)?, pageGeneration: UInt64? = nil) async throws -> JSONValue {
        guard case .object(let body) = params, case .string(let session)? = body["sessionId"], !session.isEmpty
        else { throw PageError.invalidParams(op) }
        // Never through Foundation: the tail is the chat's whole last read (cmuxterm-hq#19028).
        return try answered(await AgentPaneTailCache.answer(to: method, params: params, host: host, pageGeneration: pageGeneration))
    }

    private static func answered(_ answer: AgentPaneTailCache.Answer) throws -> JSONValue {
        switch answer {
        case .value(let value): return value
        case .refused(let message): throw PageError(code: AgentPaneTailCache.refusedCode, message: message)
        }
    }

    /// `chat.tail` (`sessionId`, `tail` or none) and `chat.tail.get` (`sessionId`): what a page last
    /// read of a chat, held in memory for the next tab that opens it (``AgentPaneTailCache``). It is
    /// the chat's, not the pane's, so the model never sees these, as with `chat.scrollAnchor`.
    static func tail(_ method: String, params: JSONValue, op: String) throws -> JSONValue {
        guard case .object(let body) = params, case .string(let session)? = body["sessionId"], !session.isEmpty
        else { throw PageError.invalidParams(op) }
        return try answered(AgentPaneTailCache.answer(to: method, params: params))
    }
}
