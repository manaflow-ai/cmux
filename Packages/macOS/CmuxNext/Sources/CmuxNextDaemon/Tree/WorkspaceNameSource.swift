import Foundation

/// The authority that supplied a workspace's current name.
@frozen public enum WorkspaceNameSource: String, Codable, Sendable, Hashable {
    /// A person or a legacy daemon supplied the name.
    case user
    /// An automatic agent naming pass supplied the name.
    case auto
}
