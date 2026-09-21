/// The remote program that keeps a terminal session durable.
public enum MobileRemoteSessionBackend: String, Codable, CaseIterable, Equatable, Sendable {
    /// An ordinary remote shell.
    case shell
    /// A named tmux workspace.
    case tmux
    /// A named Zellij workspace.
    case zellij
    /// A named Herdr workspace.
    case herdr
    /// Native protocol access to a remote cmux daemon.
    case cmuxTUI = "cmux_tui"
}
