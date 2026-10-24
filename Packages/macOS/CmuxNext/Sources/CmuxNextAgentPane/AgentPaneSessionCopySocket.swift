import Foundation

public extension AgentPaneModel {
    /// The local Unix socket used for read-only session metadata exports. Nil for a remote chat or
    /// before the handshake, so callers cannot accidentally route a local read to another host.
    var sessionCopySocketPath: String? { transport.acpmuxSocket }

    /// Reads the focused chat's metadata through its own local acpmux socket. The app uses this
    /// seam for copy actions so the transport client remains internal to the agent-pane package.
    @concurrent nonisolated static func sessionCopyInfo(socketPath: String, sessionID: String) async -> sending [String: Any]? {
        try? await AcpmuxStatusClient.call(socketPath: socketPath, method: "_acpmux/info",
                                           params: ["sessionId": sessionID], deadline: .seconds(5))
    }
}
