/// The preferred transport used to reach a terminal host.
public enum TerminalTransportPreference: String, Codable, CaseIterable, Sendable {
    /// Connect directly over raw SSH.
    case rawSSH = "raw-ssh"
    /// Connect through the cmuxd-remote daemon.
    case remoteDaemon = "cmuxd-remote"
}
