import Foundation

/// The Git diff view that best represents one status entry.
enum GitFileDiffSource: String, Equatable, Hashable, Sendable {
    case unstaged
    case staged
    case untracked

    /// CLI flag used to render this source. Untracked files use the unstaged
    /// path and are expanded to a `/dev/null` patch by the diff reader.
    var cliArgument: String {
        switch self {
        case .unstaged, .untracked: return "--unstaged"
        case .staged: return "--staged"
        }
    }
}
