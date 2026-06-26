import Foundation

/// Per-cwd customization for sidebar workspace groups. Keyed by the anchor
/// workspace's cwd. Keys containing `*` or `?` are matched as fnmatch globs;
/// otherwise they are path prefixes. Longest match wins. `~` is expanded.
public struct CmuxConfigWorkspaceGroupsDefinition: Codable, Sendable, Equatable {
    public var byCwd: [String: CmuxConfigWorkspaceGroupEntry]?

    enum CodingKeys: String, CodingKey {
        case byCwd
    }

    public init(byCwd: [String: CmuxConfigWorkspaceGroupEntry]? = nil) {
        self.byCwd = byCwd
    }
}
