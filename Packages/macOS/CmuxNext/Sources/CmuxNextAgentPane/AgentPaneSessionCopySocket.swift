import CmuxNextCompat
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

    /// The daemon-owned paths of the focused chat's session files (`_acpmux/session_files`): the
    /// harness config and settings, its native transcript and the acpmux session record. The daemon
    /// accepts this only over its local Unix socket, so the paths are always on this Mac.
    @concurrent nonisolated static func sessionCopyFiles(socketPath: String, sessionID: String) async -> sending [String: Any]? {
        try? await AcpmuxStatusClient.call(socketPath: socketPath, method: "_acpmux/session_files",
                                           params: ["sessionId": sessionID], deadline: .seconds(5))
    }

    /// Reads one session file named by `sessionCopyFiles` off the main actor. Nil when it is
    /// missing, a directory or not UTF-8 text.
    @concurrent nonisolated static func sessionCopyFileText(path: String) async -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.checked.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return try? String(blockingContentsOf: URL(fileURLWithPath: path), encoding: .utf8)
    }
}
