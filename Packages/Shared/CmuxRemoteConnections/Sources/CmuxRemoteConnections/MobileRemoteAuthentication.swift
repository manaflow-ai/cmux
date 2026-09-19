/// SSH authentication method selected by a saved profile.
public enum MobileRemoteAuthentication: String, Codable, CaseIterable, Equatable, Sendable {
    /// Password authentication, with storage chosen separately.
    case password
    /// Software or hardware signing key.
    case publicKey = "public_key"
    /// A locally available SSH signing agent.
    case agent
    /// Server prompts, including multi-factor challenges.
    case keyboardInteractive = "keyboard_interactive"
    /// Server-managed identity with no saved password, such as Tailscale SSH.
    case serverManaged = "server_managed"
}
