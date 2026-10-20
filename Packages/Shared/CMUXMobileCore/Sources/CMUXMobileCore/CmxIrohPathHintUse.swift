/// The routing tier assigned to an Iroh path hint.
public enum CmxIrohPathHintUse: String, Codable, Sendable {
    /// A public Iroh-native path that may be attempted normally.
    case primary
    /// A private path that may be attempted only after primary paths.
    case fallbackOnly = "fallback_only"
}
