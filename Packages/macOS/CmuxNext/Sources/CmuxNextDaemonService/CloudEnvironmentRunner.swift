public import CmuxNextAgentPane
public import CmuxNextDaemon
public import Foundation

/// Runs the native Cloud environment request after the app supplies its signed-in token.
public enum CloudEnvironmentRunner {
    @MainActor
    public static func run(
        _ request: AgentPaneCloudEnvironmentRequest,
        allowed: Bool,
        connection: DaemonConnection?,
        platform: URL?,
        accessToken: @escaping @MainActor () async throws -> String
    ) async -> [String: Any] {
        guard allowed, let connection, let platform else {
            return AgentPaneReply.failure(code: "cloud_disabled", message: "cloud_disabled")
        }
        do {
            let value = try await connection.request(
                CloudEnvironmentRequest(action: request.action, params: request.params,
                                        platformOrigin: platform.absoluteString, accessToken: try await accessToken()),
                timeout: .seconds(30))
            return AgentPaneReply.success(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed]))
        } catch DaemonError.command(_, let message, let code, _, _) {
            return AgentPaneReply.failure(code: code ?? "cloud_environment.failed", message: message)
        } catch {
            return AgentPaneReply.failure(code: "cloud_environment.unavailable", message: "cloud_environment.unavailable")
        }
    }
}
