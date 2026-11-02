public import CmuxNextDaemon
import Foundation

/// A forwarding envelope only. The shared web editor and Rust validate fields.
public nonisolated struct AgentPaneCloudEnvironmentRequest: Equatable, Sendable {
    public static let methods: Set<String> = [
        "cloud.environment.list", "cloud.environment.get", "cloud.environment.update", "cloud.environment.derive",
    ]
    public let action: String
    public let params: JSONValue

    init?(method: String, params: [String: Any]?) {
        guard Self.methods.contains(method), let action = method.split(separator: ".").last,
              let data = try? JSONSerialization.data(withJSONObject: params ?? [:]),
              let params = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        self.action = String(action)
        self.params = params
    }
}
