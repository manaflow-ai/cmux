import Foundation
import os

/// Gives a signed acpmux the legacy Computer Use agent endpoint only after
/// both sides verified the connected socket peer. This lifecycle operation is
/// intentionally not a CLI, MCP, palette, remote-relay or public WebSocket
/// surface: it carries a per-launch credential from the containing app.
nonisolated enum AcpmuxComputerUse {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.acpmux")
    static let enrollmentMethod = "_acpmux/computer_use_enroll"

    static func enrollmentParameters(_ environment: AcpmuxEnvironment) -> [String: any Sendable] {
        [
            "socket": environment.computerUse["CMUX_NEXT_CUA_SOCKET"] ?? "",
            "agentToken": environment.computerUse["CMUX_NEXT_CUA_SOCKET_AUTH_TOKEN"] ?? "",
        ]
    }

    /// The app checks the server on the connection that carries the credential;
    /// acpmux independently accepts it only from its containing signed app.
    static func enroll(_ environment: AcpmuxEnvironment) async {
        guard !environment.passesPersonKeyAtSpawn else { return }
        do {
            _ = try await AcpmuxServerPeer.call(
                socketPath: environment.socketPath,
                method: enrollmentMethod,
                params: enrollmentParameters(environment),
                executable: environment.executable,
                deadline: .seconds(5)
            )
        } catch {
            logger.error("acpmux Computer Use enrollment refused: \(String(describing: error), privacy: .public)")
        }
    }
}
