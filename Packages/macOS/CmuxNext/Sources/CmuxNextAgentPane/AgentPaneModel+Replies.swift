import Foundation

extension AgentPaneModel {
    /// The page's reply for a failed git read: the failure's code, origin,
    /// details and retryable under the localized text.
    static func gitFailure(_ failure: AgentPaneGitFailure, message: String = gitFailedMessage) -> [String: Any] {
        let details = failure.details.flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
        return AgentPaneReply.failure(
            code: failure.code, message: message, details: details,
            retryable: failure.retryable, origin: failure.origin.rawValue)
    }

    /// The page's reply for a git read or write: its JSON result, else the
    /// failure under `message`. A result that is not JSON is `native.failed`.
    static func gitReply(message: String, _ run: () async throws -> Data) async -> [String: Any] {
        do {
            let data = try await run()
            guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                return gitFailure(.failed, message: message)
            }
            return AgentPaneReply.success(value)
        } catch {
            return gitFailure(error as? AgentPaneGitFailure ?? .failed, message: message)
        }
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
