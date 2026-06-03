/// The origin of a terminal host record.
public enum TerminalHostSource: String, Codable, CaseIterable, Sendable {
    /// The host was discovered automatically (e.g. from server metadata or mobile sync).
    case discovered
    /// The host was created or edited by the user.
    case custom
}
