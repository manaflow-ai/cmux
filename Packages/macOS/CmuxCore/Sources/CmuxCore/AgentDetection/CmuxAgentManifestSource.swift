/// Identifies where an admitted manifest came from.
public enum CmuxAgentManifestSource: String, Codable, Hashable, Sendable {
    /// A manifest shipped in the application bundle.
    case bundled
    /// A manifest loaded from the user's override directory.
    case user
}
