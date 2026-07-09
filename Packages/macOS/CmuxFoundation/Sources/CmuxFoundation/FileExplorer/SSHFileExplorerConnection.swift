/// Connection parameters for reaching a remote host over SSH in the file explorer.
///
/// A pure value identifying an SSH endpoint: its `destination`, optional `port`,
/// optional `identityFile`, and extra `sshOptions`. Equatable so the store can
/// detect when a workspace's remote root still targets the same host.
public struct SSHFileExplorerConnection: Equatable, Sendable {
    /// SSH destination (`user@host` or host alias).
    public let destination: String
    /// Optional port override.
    public let port: Int?
    /// Optional identity (private key) file path.
    public let identityFile: String?
    /// Extra `-o` options passed to `ssh`.
    public let sshOptions: [String]

    /// Creates an SSH connection descriptor.
    public init(destination: String, port: Int?, identityFile: String?, sshOptions: [String]) {
        self.destination = destination
        self.port = port
        self.identityFile = identityFile
        self.sshOptions = sshOptions
    }
}
