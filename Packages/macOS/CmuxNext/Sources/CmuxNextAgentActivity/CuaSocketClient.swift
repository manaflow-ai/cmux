public import Foundation

/// The local CUA host socket: each request writes a line out, reads one reply
/// line back within `deadline`, and returns the `result` object on `ok`.
/// Shared by the activity pane and onboarding's computer use step
/// (`permissions_status`).
public struct CuaSocketClient: Sendable {
    public let configuration: AgentActivitySocketSource.Configuration

    public init(configuration: AgentActivitySocketSource.Configuration) {
        self.configuration = configuration
    }

    public func send(_ method: String, _ args: [String: Any] = [:],
                     deadline: Duration = .seconds(5)) async throws -> [String: Any] {
        let line = AgentActivityWire.requestLine(method: method, args: args, authToken: configuration.authToken,
                                                 hostAuthToken: configuration.hostAuthToken)
        let data = try await AgentActivityLineConnection.oneShot(path: configuration.socketPath, send: line,
                                                                 deadline: deadline, expectedServerUID: geteuid())
        guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentActivitySourceError.malformed
        }
        guard reply["ok"] as? Bool == true else {
            throw AgentActivitySourceError.refused(reply["error"] as? String ?? "error")
        }
        return reply["result"] as? [String: Any] ?? [:]
    }
}
