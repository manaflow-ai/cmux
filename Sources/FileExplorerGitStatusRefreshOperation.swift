import Foundation

struct FileExplorerGitStatusRefreshOperation {
    let identifier: UUID
    let source: FileExplorerGitStatusRefreshSource
    let task: Task<Void, Never>
}
