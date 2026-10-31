import CmuxNextPages
import CmuxNextSettings
import Foundation

extension AgentPageProvider {
    /// `chat.scrollAnchor` (`sessionId`, `rowId` or null, `offset`) and `chat.scrollAnchor.get`
    /// (`sessionId`): a chat's kept place in ``AgentPaneScrollAnchors/shared`` (cx-6bgzj). It is
    /// the chat's, not the pane's, so the model never sees these.
    static func scrollAnchor(_ method: String, params: JSONValue, op: String) throws -> JSONValue {
        let body = params.foundationObject as? [String: Any]
        guard let session = body?["sessionId"] as? String, !session.isEmpty else { throw PageError.invalidParams(op) }
        guard let anchors = AgentPaneScrollAnchors.shared else { return .null }
        if method == "chat.scrollAnchor.get" {
            guard let anchor = anchors.anchor(for: session) else { return .null }
            return .object(["rowId": .string(anchor.rowId), "offset": .number(anchor.offset)])
        }
        let row = body?["rowId"] as? String
        let offset = (body?["offset"] as? NSNumber)?.doubleValue ?? 0
        guard anchors.remember(row.map { AgentPaneScrollAnchor(rowId: $0, offset: offset) }, for: session) else { throw PageError.closed }
        return .null
    }
}
