/// Why the inline VS Code server could not serve a request.
public enum VSCodeServeWebError: Error, Equatable, Sendable {
    /// The VS Code install has no directly trusted cached `code-server`.
    case serverMissing
    /// The private connection token file could not be written.
    case tokenFileFailed
    /// The server process could not be started; the payload is the system's reason.
    case launchFailed(String)
    /// The server exited before it printed its Web UI URL.
    case exitedBeforeReady
    /// The server did not print its Web UI URL before the startup deadline.
    case startupTimedOut
    /// The server was stopped (Stop or Restart) while this request waited for it.
    case stopped
}
