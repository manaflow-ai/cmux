public import CmuxNextDaemon
import Foundation

private nonisolated extension JSONValue {
    var objectValue: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
    var intValue: Int? {
        guard case .number(let value) = self, value.rounded() == value, abs(value) < 1e15 else { return nil }
        return Int(value)
    }
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
    public static let methods: Set<String> = [
        "cloud.repo.local", "cloud.repo.sync", "cloud.repo.list", "cloud.repo.add", "cloud.repo.attached", "cloud.repo.wait_github",
    ]
    public let method: String
    public let params: JSONValue

    init?(method: String, params: [String: Any]?) {
        let raw = params ?? [:]
        guard Self.methods.contains(method),
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              Self.valid(method: method, params: value) else { return nil }
        self.method = method
        self.params = value
    }

    private static func valid(method: String, params: JSONValue) -> Bool {
        let object = params.objectValue ?? [:]
        switch method {
        case "cloud.repo.local": return object.isEmpty
        case "cloud.repo.sync":
            return object["repos"]?.arrayValue != nil
                && object.keys.allSatisfy { ["repos", "recent", "complete", "install_url"].contains($0) }
        case "cloud.repo.list", "cloud.repo.attached":
            return (object["session"] == nil || session(object["session"]) != nil) && (object.keys.allSatisfy { ["session", "query"].contains($0) })
        case "cloud.repo.add":
            return (object["session"] == nil || session(object["session"]) != nil) && repo(object["repo"]) != nil && object.keys.allSatisfy { ["session", "repo", "ref"].contains($0) }
        case "cloud.repo.wait_github":
            guard object.keys.allSatisfy({ ["session", "timeout_ms"].contains($0) }),
                  object["session"] == nil || session(object["session"]) != nil else { return false }
            if let timeout = object["timeout_ms"]?.intValue { return (0...60_000).contains(timeout) }
            return object["timeout_ms"] == nil
        default: return false
        }
    }

    private static func session(_ value: JSONValue?) -> String? {
        guard let value, let string = value.stringValue, string.range(of: #"^[A-Za-z0-9_.:-]{1,128}$"#, options: .regularExpression) != nil else { return nil }
        return string
    }

    private static func repo(_ value: JSONValue?) -> String? {
        guard let value, let string = value.stringValue, !string.isEmpty, string.utf8.count <= 2048, !string.contains("\0") else { return nil }
        return string
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
            var sendable = params.sendableObject as! [String: any Sendable]
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
