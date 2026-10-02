public import Foundation

/// One request to the local CUA host socket: a line out, one reply line back
/// within `deadline`, the `result` object on `ok`. Shared by the activity
/// pane and onboarding's computer use step (`permissions_status`).
public enum CuaSocketRequest {
    public static func send(_ method: String, _ args: [String: Any] = [:],
                            configuration config: AgentActivitySocketSource.Configuration,
                            deadline: Duration = .seconds(5)) async throws -> [String: Any] {
        let line = AgentActivityWire.requestLine(method: method, args: args, authToken: config.authToken,
                                                 hostAuthToken: config.hostAuthToken)
        let data = try await AgentActivityLineConnection.oneShot(path: config.socketPath, send: line, deadline: deadline)
        guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentActivitySourceError.malformed
        }
        guard reply["ok"] as? Bool == true else {
            throw AgentActivitySourceError.refused(reply["error"] as? String ?? "error")
        }
        return reply["result"] as? [String: Any] ?? [:]
    }
}
