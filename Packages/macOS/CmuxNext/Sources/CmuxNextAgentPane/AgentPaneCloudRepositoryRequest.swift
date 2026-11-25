public import CmuxNextDaemon
import Foundation

private nonisolated extension JSONValue {
    var sendableObject: any Sendable {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let values): values.map(\.sendableObject)
        case .object(let values): values.mapValues(\.sendableObject)
        }
    }
}

/// The Mac daemon's local catalog read. This uses the raw cmux-tui command path; it is not an
/// acpmux JSON-RPC method and does not carry a chat session.
public struct AgentPaneCloudRepositoryLocalRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "cloud.repo.local"

    public init() {}
}

/// The Cloud repository actions are daemon-owned. The page host only validates the action shape
/// and forwards it over the pane's authenticated cmux-tui daemon frame; it never handles repository data.
public nonisolated struct AgentPaneCloudRepositoryRequest: Equatable, Sendable {
    public let method: String
    public let params: JSONValue

    /// Rust checked the action's shape (``AgentPaneRequest/rustHostOp(method:params:)``).
    init(method: String, params: JSONValue) {
        self.method = method
        self.params = params
    }

    /// Forwards a validated action. Typed repository failures are successful daemon results and
    /// remain in `value`, so the web card can render the next action without treating it as transport failure.
    func reply(remoteChat: Bool, sessionID: String?,
               request: (@Sendable (String, [String: any Sendable], Duration?) async throws -> Data)? = nil,
               localRequest: (@MainActor () async throws -> Data)? = nil) async -> [String: Any] {
        guard remoteChat || method == "cloud.repo.local" || method == "cloud.repo.sync" else {
            return AgentPaneReply.failure(code: "unavailable", message: "Cloud repository actions require a Cloud chat.")
        }
        if method != "cloud.repo.local", method != "cloud.repo.sync" {
            guard sessionID != nil else {
                return AgentPaneReply.failure(code: "cloud_repo.session_mismatch", message: "Cloud repository action does not belong to this chat.")
            }
        }
        do {
            guard case let .object(values) = params else {
                return AgentPaneReply.failure(code: "seed.bad_request", message: "Cloud repository parameters must be an object.")
            }
            var sendable = values.mapValues(\.sendableObject)
            if method != "cloud.repo.local", method != "cloud.repo.sync", let sessionID {
                // The page never chooses the session. Bind this frame to the pane's own chat.
                sendable["session"] = sessionID
            }
            let deadline: Duration? = method == "cloud.repo.wait_github" ? .seconds(65) : .seconds(120)
            let data: Data
            if method == "cloud.repo.local" {
                guard let localRequest else {
                    return AgentPaneReply.failure(code: "cloud_repo.unavailable", message: "Cloud repository service unavailable.")
                }
                data = try await localRequest()
            } else {
                guard let request else {
                    return AgentPaneReply.failure(code: "cloud_repo.unavailable", message: "Cloud repository service unavailable.")
                }
                data = try await request(method, sendable, deadline)
            }
            let value = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            return AgentPaneReply.success(value)
        } catch let error as AgentSessionRemoteError {
            return AgentPaneReply.failure(code: error.code, message: error.message)
        } catch let error as AgentSessionAttachError {
            return AgentPaneReply.failure(code: error.code, message: error.message)
        } catch {
            return AgentPaneReply.failure(code: "cloud_repo.unavailable", message: "Cloud repository service unavailable.")
        }
    }
}
