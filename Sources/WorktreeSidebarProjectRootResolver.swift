/// Resolves checkouts to Git's first worktree while coalescing rapid cwd changes.
actor WorktreeSidebarProjectRootResolver {
    private struct Request: Sendable {
        let directory: String
        let continuation: CheckedContinuation<String?, Never>
    }

    private let git: any WorktreeSidebarGitOperating
    private var isResolving = false
    private var pendingRequest: Request?

    init(git: (any WorktreeSidebarGitOperating)? = nil) {
        self.git = git ?? WorktreeSidebarGitService()
    }

    func projectRoot(onDiskFor directory: String) async -> String? {
        await withCheckedContinuation { continuation in
            enqueue(Request(directory: directory, continuation: continuation))
        }
    }

    private func enqueue(_ request: Request) {
        guard isResolving else {
            isResolving = true
            Task { await resolve(request) }
            return
        }
        pendingRequest?.continuation.resume(returning: nil)
        pendingRequest = request
    }

    private func resolve(_ initialRequest: Request) async {
        var currentRequest: Request? = initialRequest
        while let request = currentRequest {
            let worktrees = try? await git.listWorktrees(projectRootPath: request.directory)
            request.continuation.resume(returning: worktrees?.first?.path)
            currentRequest = pendingRequest
            pendingRequest = nil
        }
        isResolving = false
    }
}
