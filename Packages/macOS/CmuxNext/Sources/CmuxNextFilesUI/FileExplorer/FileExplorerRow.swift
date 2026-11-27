package import Foundation

/// One visible row of the file explorer's tree: a value snapshot the table
/// shows (rows never hold the model).
package nonisolated struct FileExplorerRow: Equatable, Sendable {
    package var url: URL
    package var name: String
    /// 0 for the root folder's children, one more per expanded folder level.
    package var depth: Int
    package var isFolder: Bool
    package var isExpanded: Bool
    /// The item's git state; nil when clean or outside a repository.
    package var git: FileGitState?

    package init(url: URL, name: String, depth: Int, isFolder: Bool, isExpanded: Bool, git: FileGitState? = nil) {
        self.url = url
        self.name = name
        self.depth = depth
        self.isFolder = isFolder
        self.isExpanded = isExpanded
        self.git = git
    }
}
