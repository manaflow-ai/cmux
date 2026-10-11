import Foundation

/// The local cmux socket a remote workspace's CLI relay and cloud CLI bridge
/// forward commands to.
///
/// `workspace.remote.configure` takes a `local_socket_path` parameter, which
/// the CLI fills with the socket it connected through. The relay and bridge
/// forward remote commands to the stored path, so the app always stores its
/// own control socket there. The client's value only says whether forwarding
/// is wanted.
///
/// ```swift
/// let localSocketPath = ControlWorkspaceRemoteLocalSocketPath(
///     controllerSocketPath: currentSocketPathForRemoteRestore()
/// ).resolved(requested: v2RawString(params, "local_socket_path"))
/// ```
public struct ControlWorkspaceRemoteLocalSocketPath: Sendable, Equatable {
    /// The path this app's control socket listens on, or `nil` when the app
    /// has no control socket.
    public let controllerSocketPath: String?

    /// Creates the resolver for this app's control socket.
    ///
    /// - Parameter controllerSocketPath: The path this app's control socket
    ///   listens on. A missing or blank value means the app has no socket to
    ///   forward to, so ``resolved(requested:)`` always returns `nil`.
    public init(controllerSocketPath: String?) {
        self.controllerSocketPath = controllerSocketPath
    }

    /// The socket path to store in the remote configuration.
    ///
    /// - Parameter requested: The client's `local_socket_path` parameter. A
    ///   missing or blank value means the client did not ask for command
    ///   forwarding. Any other value turns forwarding on; the path itself is
    ///   ignored.
    /// - Returns: ``controllerSocketPath`` when the client asked for
    ///   forwarding and the app has a control socket, otherwise `nil`.
    public func resolved(requested: String?) -> String? {
        guard let requested,
              !requested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let controllerSocketPath = controllerSocketPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !controllerSocketPath.isEmpty else {
            return nil
        }
        return controllerSocketPath
    }
}
