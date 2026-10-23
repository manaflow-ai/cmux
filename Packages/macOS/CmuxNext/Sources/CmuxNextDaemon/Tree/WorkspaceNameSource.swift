import Foundation

/// The authority that supplied a workspace's current name.
public enum WorkspaceNameSource: String, Codable, Sendable, Hashable {
    /// A person or a legacy daemon supplied the name.
    public case user
    /// An automatic agent naming pass supplied the name.
    public case auto
}
