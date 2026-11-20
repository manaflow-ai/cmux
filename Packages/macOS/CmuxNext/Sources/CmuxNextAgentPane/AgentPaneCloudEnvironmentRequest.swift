public import CmuxNextDaemon
import Foundation

/// A forwarding envelope only. The shared web editor and Rust validate fields.
public nonisolated struct AgentPaneCloudEnvironmentRequest: Equatable, Sendable {
    public static let methods: Set<String> = [
        "cloud.environment.list", "cloud.environment.get", "cloud.environment.update", "cloud.environment.derive",
        "cloud.environment.create",
    ]
    public let action: String
    public let params: JSONValue

    /// Nil for a method outside ``methods`` or params that are not JSON (the composer, Settings > Cloud Environments).
    public init?(method: String, params: [String: Any]?) {
        guard Self.methods.contains(method), let action = method.split(separator: ".").last,
              let data = try? JSONSerialization.data(withJSONObject: params ?? [:]),
              let params = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        self.action = String(action)
        self.params = params
    }
}
