import Foundation

/// One visible row of the file explorer's tree: a value snapshot the table
/// shows (rows never hold the model).
nonisolated struct FileExplorerRow: Equatable, Sendable {
    var url: URL
    var name: String
    /// 0 for the root folder's children, one more per expanded folder level.
    var depth: Int
    var isFolder: Bool
    var isExpanded: Bool
    /// The item's git state; nil when clean or outside a repository.
    var git: FileGitState?
}
