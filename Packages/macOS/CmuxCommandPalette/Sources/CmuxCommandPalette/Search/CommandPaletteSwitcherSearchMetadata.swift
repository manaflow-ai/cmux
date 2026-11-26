import Foundation

/// Searchable workspace/surface metadata (directories, git branches, ports,
/// and the user description) feeding the switcher search corpus.
public struct CommandPaletteSwitcherSearchMetadata: Equatable, Sendable {
    /// Working directories associated with the workspace or surface.
    public let directories: [String]
    /// Git branches associated with the workspace or surface.
    public let branches: [String]
    /// Listening ports associated with the workspace or surface.
    public let ports: [Int]
    /// Optional user-provided description.
    public let description: String?

    /// Creates metadata; all fields default to empty.
    public init(
        directories: [String] = [],
        branches: [String] = [],
        ports: [Int] = [],
        description: String? = nil
    ) {
        self.directories = directories
        self.branches = branches
        self.ports = ports
        self.description = description
    }

    /// Feeds the metadata into `hasher` for switcher change detection
    /// (order- and count-sensitive).
    public func combine(into hasher: inout Hasher) {
        hasher.combine(directories.count)
        for directory in directories {
            hasher.combine(directory)
        }
        hasher.combine(branches.count)
        for branch in branches {
            hasher.combine(branch)
        }
        hasher.combine(ports.count)
        for port in ports {
            hasher.combine(port)
        }
        hasher.combine(description ?? "")
    }
}
