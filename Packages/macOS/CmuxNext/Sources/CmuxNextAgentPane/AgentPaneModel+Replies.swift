import Foundation

extension AgentPaneModel {
    /// The Foundation value of a git reply, parsed off the main actor; nil
    /// when the bytes are not JSON.
    @concurrent
    nonisolated static func parseGitReply(_ data: Data) async -> GitReplyValue? {
        (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])).map(GitReplyValue.init)
    }

    /// A parsed JSON value (Foundation containers nobody mutates after the
    /// parse) handed from the parsing task to the main actor.
    // crash-allow: a JSONSerialization result (immutable Foundation containers), handed once from the parse task to the main actor.
    nonisolated struct GitReplyValue: @unchecked Sendable {
        let value: Any
    }

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

    /// `transport.gestureRelease` forgets the gesture tickets; `transport.close` closes its connection.
    func endTransport(closing connection: Int?) -> [String: Any] {
        if let connection { transport.close(connection: connection) } else { transport.gestures.clearTickets() }
        return AgentPaneReply.success()
    }

    static func unsupported(_ method: String) -> [String: Any] {
        AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: \(method)")
    }
}
