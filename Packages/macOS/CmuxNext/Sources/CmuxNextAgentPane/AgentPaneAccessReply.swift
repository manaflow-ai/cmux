public import CmuxNextSettings

/// What the App answers an ``AgentPaneAccessRequest``: a value for the page, or a refusal with a
/// code and the sentence the card shows.
public nonisolated enum AgentPaneAccessReply: Sendable, Equatable {
    case success([String: JSONValue])
    case failure(code: String, message: String)

    /// The page's reply envelope.
    var page: [String: Any] {
        switch self {
        case .success(let value): AgentPaneReply.success(JSONValue.object(value).foundationObject)
        case .failure(let code, let message): AgentPaneReply.failure(code: code, message: message)
        }
    }
}
