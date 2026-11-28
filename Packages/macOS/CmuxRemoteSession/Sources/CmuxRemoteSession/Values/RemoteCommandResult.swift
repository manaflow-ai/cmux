/// The captured outcome of one finished remote-session subprocess
/// (`ssh`, `scp`, or the dev-only `go build` fallback).
///
/// Lifted from the legacy `WorkspaceRemoteSessionController.CommandResult`
/// (renamed per the Workspace decomposition plan).
public struct RemoteCommandResult: Sendable {
    /// The process termination status.
    public let status: Int32
    /// Captured standard output, decoded as UTF-8 (empty when undecodable).
    public let stdout: String
    /// Captured standard error, decoded as UTF-8 (empty when undecodable).
    public let stderr: String

    /// Creates a result from a finished process's captured streams.
    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}
