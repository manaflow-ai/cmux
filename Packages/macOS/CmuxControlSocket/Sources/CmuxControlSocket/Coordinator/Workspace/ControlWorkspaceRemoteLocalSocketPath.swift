/// The local cmux socket a remote workspace's CLI relay and cloud CLI bridge
/// forward commands to.
///
/// `workspace.remote.configure` takes a `local_socket_path` parameter, which
/// the CLI fills with the socket it connected through. The relay and bridge
/// then forward remote commands to that path.
public enum ControlWorkspaceRemoteLocalSocketPath {
    /// The socket path to store in the remote configuration.
    ///
    /// - Parameters:
    ///   - requested: The client's `local_socket_path` parameter. A missing or
    ///     blank value means the client did not ask for command forwarding.
    ///   - controllerSocketPath: The path this app's control socket listens on.
    /// - Returns: The path to forward to, or `nil` to leave forwarding off.
    public static func resolved(requested: String?, controllerSocketPath: String?) -> String? {
        requested
    }
}
