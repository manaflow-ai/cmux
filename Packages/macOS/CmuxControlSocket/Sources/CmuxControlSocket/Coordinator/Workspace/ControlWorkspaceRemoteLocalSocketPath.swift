import Foundation

/// The local cmux socket a remote workspace's CLI relay and cloud CLI bridge
/// forward commands to.
///
/// `workspace.remote.configure` takes a `local_socket_path` parameter, which
/// the CLI fills with the socket it connected through. The relay and bridge
/// forward remote commands to the stored path, so the app always stores its
/// own control socket there. The client's value only says whether forwarding
/// is wanted.
public enum ControlWorkspaceRemoteLocalSocketPath {
    /// The socket path to store in the remote configuration.
    ///
    /// - Parameters:
    ///   - requested: The client's `local_socket_path` parameter. A missing or
    ///     blank value means the client did not ask for command forwarding.
    ///     Any other value turns forwarding on; the path itself is ignored.
    ///   - controllerSocketPath: The path this app's control socket listens on.
    /// - Returns: `controllerSocketPath` when the client asked for forwarding
    ///   and the app has a control socket, otherwise `nil`.
    public static func resolved(requested: String?, controllerSocketPath: String?) -> String? {
        guard let requested,
              !requested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let controllerSocketPath = controllerSocketPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !controllerSocketPath.isEmpty else {
            return nil
        }
        return controllerSocketPath
    }
}
