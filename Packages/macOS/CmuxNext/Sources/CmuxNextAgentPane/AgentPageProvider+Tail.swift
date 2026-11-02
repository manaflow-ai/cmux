import CmuxNextPages
import CmuxNextSettings
import Foundation

extension AgentPageProvider {
    /// `chat.tail` (`sessionId`, `tail` or none) and `chat.tail.get` (`sessionId`): what a page last
    /// read of a chat, held in memory for the next tab that opens it (``AgentPaneTailCache``). It is
    /// the chat's, not the pane's, so the model never sees these, as with `chat.scrollAnchor`.
    static func tail(_ method: String, params: JSONValue, op: String) throws -> JSONValue {
        guard case .object(let body) = params, case .string(let session)? = body["sessionId"], !session.isEmpty
        else { throw PageError.invalidParams(op) }
        let cache = AgentPaneTailCache.shared
        if method == "chat.tail.get" { return cache.tail(for: session) ?? .null }
        // No tail, or one this refuses: the chat is forgotten here, so no tab draws a transcript
        // this page no longer stands behind.
        // A hover's hand-over (`ifNewer`) never replaces a tail that ends on the same or a newer record.
        if case .bool(true)? = body["ifNewer"] {
            if let tail = body["tail"] { cache.rememberIfNewer(tail, for: session) }
        } else {
            cache.remember(body["tail"], for: session)
        }
        return .null
    }
}
