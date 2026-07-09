/// A validated SSH endpoint parsed from `remote.tmux.*` socket params, lifted
/// byte-faithfully from `TerminalController.remoteTmuxHost(from:)`.
///
/// Carries only the three socket-supplied fields (`destination`, `port`,
/// `identityFile`); the app conforms ``ControlRemoteTmuxReading`` and rebuilds
/// the app-side `RemoteTmuxHost` (and its ControlMaster-socket / argv logic)
/// from these values. The `destination` is the SSH `~/.ssh/config` alias or
/// `user@host`. This package owns no SSH or process machinery — the value is a
/// pure transfer object across the worker→app seam.
public struct ControlRemoteTmuxHost: Sendable, Equatable {
    /// The SSH destination: a `~/.ssh/config` alias or `user@host`.
    public let destination: String

    /// Optional explicit port (`-p`); `nil` defers to `~/.ssh/config`. Already
    /// range-validated (1...65535) by ``ControlRemoteTmuxWorker`` at the trust
    /// boundary, matching the legacy `remoteTmuxHost(from:)` rejection.
    public let port: Int?

    /// Optional explicit identity file (`-i`); `nil` defers to `~/.ssh/config`.
    public let identityFile: String?

    /// Creates a validated remote-tmux host.
    ///
    /// - Parameters:
    ///   - destination: The SSH destination (alias or `user@host`).
    ///   - port: Optional explicit port.
    ///   - identityFile: Optional explicit identity file.
    public init(destination: String, port: Int?, identityFile: String?) {
        self.destination = destination
        self.port = port
        self.identityFile = identityFile
    }
}
