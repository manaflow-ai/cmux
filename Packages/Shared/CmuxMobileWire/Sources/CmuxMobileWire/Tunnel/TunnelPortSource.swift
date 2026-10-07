/// Why the Mac lets a port be forwarded.
public enum TunnelPortSource: String, Hashable, Sendable, Codable, CaseIterable {
    /// A listener owned by a process of the user's workspaces.
    case detected
    /// A port the user allowed on the Mac.
    case allowed
}
