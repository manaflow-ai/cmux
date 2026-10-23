import Foundation

/// The authority that supplied a workspace's current name.
public enum WorkspaceNameSource: String, Codable, Sendable, Hashable {
    /// A person or a legacy daemon supplied the name.
    case user
    /// An automatic agent naming pass supplied the name.
    case auto

    /// The automatic source exposed to public default arguments across package targets.
    public static let automatic: Self = .auto
}
