/// The authentication method used when connecting to a host over SSH.
public enum TerminalSSHAuthenticationMethod: String, Codable, CaseIterable, Sendable {
    /// Authenticate with a saved password.
    case password
    /// Authenticate with a saved private key.
    case privateKey = "private-key"
}
