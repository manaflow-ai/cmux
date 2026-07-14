import Foundation

/// Focus-preserving request for a stable interactive terminal in a worktree.
struct WorktreeSidebarWorkspaceRequest: Equatable, Sendable {
    let title: String
    let workingDirectory: String
    let inheritWorkingDirectory = false
    let select = false
    let eagerLoadTerminal = true

    init(worktreePath: String, title: String? = nil) {
        let url = URL(fileURLWithPath: worktreePath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let directoryName = url.lastPathComponent
        self.title = title ?? (directoryName.isEmpty ? url.path : directoryName)
        workingDirectory = url.path
    }
}
