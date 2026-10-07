import Foundation

extension AgentPaneModel {
    /// The page's reply for a failed git read: the failure's code, origin,
    /// details and retryable under the localized text.
    static func gitFailure(_ failure: AgentPaneGitFailure) -> [String: Any] {
        let details = failure.details.flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
        return AgentPaneReply.failure(
            code: failure.code, message: gitFailedMessage, details: details,
            retryable: failure.retryable, origin: failure.origin.rawValue)
    }

    /// The page's reply to a `transport.send`.
    static func transportReply(_ error: AgentPaneTransportError?) -> [String: Any] {
        error.map(transportFailure) ?? AgentPaneReply.success()
    }

    static func transportFailure(_ error: AgentPaneTransportError) -> [String: Any] {
        AgentPaneReply.failure(code: error.rawValue, message: transportFailedMessage, details: nil, retryable: nil, origin: "native")
    }

    static func unsupported(_ method: String) -> [String: Any] {
        AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: \(method)")
    }
}
