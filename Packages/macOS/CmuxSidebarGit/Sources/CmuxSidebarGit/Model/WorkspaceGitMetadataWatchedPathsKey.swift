import Foundation

/// Identifies one shared filesystem watcher by its normalized watched paths.
struct WorkspaceGitMetadataWatchedPathsKey: Equatable, Hashable, Sendable {
    let paths: [String]

    init(paths: [String]) {
        self.paths = Array(Set(paths)).sorted()
    }
}
