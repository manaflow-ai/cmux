public import Foundation

/// The local CUA host socket: each request writes a line out, reads one reply
/// line back within `deadline`, and returns the `result` object on `ok`.
/// Shared by the activity pane and onboarding's computer use step
/// (`permissions_status`). Nonisolated: a request runs where its caller runs, so a caller off the
/// main actor (the live preview's frame loads, Computer Use Setup's grant request) also parses the reply there.
public nonisolated struct CuaSocketClient: Sendable {
    public let configuration: AgentActivitySocketSource.Configuration

    public init(configuration: AgentActivitySocketSource.Configuration) {
        self.configuration = configuration
    }

    // nonisolated: the struct is Sendable and reads only its `let` configuration, so the
    // reply is built off the main actor and never crosses an actor boundary (the
    // nonisolated caller `socketRequestGrant` failed to compile without this).
    public nonisolated func send(_ method: String, name: String? = nil, _ args: [String: Any] = [:],
                                 deadline: Duration = .seconds(5)) async throws -> [String: Any] {
        let line = AgentActivityWire.requestLine(method: method, name: name, args: args, authToken: configuration.authToken,
                                                 hostAuthToken: configuration.hostAuthToken)
        let data = try await AgentActivityLineConnection.oneShot(path: configuration.socketPath, send: line,
                                                                 deadline: deadline,
                                                                 acceptsServer: CuaHelperIdentity.isHelperServer)
        guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentActivitySourceError.malformed
        }
        guard reply["ok"] as? Bool == true else {
            throw AgentActivitySourceError.refused(reply["error"] as? String ?? "error")
        }
        return reply["result"] as? [String: Any] ?? [:]
    }
}
