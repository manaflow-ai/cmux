import CmuxGit

struct FileExplorerGitStatusRefreshRequest: Sendable {
    let generation: Int
    let source: FileExplorerGitStatusRefreshSource

#if compiler(>=6.2)
    @concurrent
#endif
    nonisolated func fetch(
        using provider: GitStatusProvider,
        previousStatus: [String: GitFileStatus]
    ) async -> FileExplorerGitStatusRefreshResult {
        let status: [String: GitFileStatus]
        switch source {
        case .local(let directory):
            status = await provider.fetchStatus(
                directory: directory,
                preserving: previousStatus
            )
        case .ssh(
            let directory,
            let destination,
            let port,
            let identityFile,
            let options
        ):
            status = await provider.fetchStatusSSH(
                directory: directory,
                destination: destination,
                port: port,
                identityFile: identityFile,
                sshOptions: options,
                preserving: previousStatus
            )
        }
        return FileExplorerGitStatusRefreshResult(
            status: status,
            diff: FileExplorerStore.gitStatusDiff(
                previous: previousStatus,
                current: status
            )
        )
    }
}
