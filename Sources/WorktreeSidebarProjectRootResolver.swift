import Foundation

/// Serial resolver with one Git listing in flight and one pending request per workspace.
actor WorktreeSidebarProjectRootResolver {
    private let git: any WorktreeSidebarGitOperating
    private var isResolving = false
    private var pendingOrder = WorktreeSidebarRequesterQueue()
    private var pendingRequests: [UUID: WorktreeSidebarProjectRootRequest] = [:]

    init(git: (any WorktreeSidebarGitOperating)? = nil) {
        self.git = git ?? WorktreeSidebarGitService()
    }

    func projectRoot(
        onDiskFor directory: String,
        requesterID: UUID = UUID()
    ) async -> String? {
        await withCheckedContinuation { continuation in
            enqueue(WorktreeSidebarProjectRootRequest(
                requesterID: requesterID,
                directory: directory,
                continuation: continuation
            ))
        }
    }

    private func enqueue(_ request: WorktreeSidebarProjectRootRequest) {
        guard isResolving else {
            isResolving = true
            Task { await resolve(request) }
            return
        }
        if let previous = pendingRequests.updateValue(request, forKey: request.requesterID) {
            previous.continuation.resume(returning: nil)
        } else {
            pendingOrder.enqueue(request.requesterID)
        }
    }

    private func resolve(_ initialRequest: WorktreeSidebarProjectRootRequest) async {
        var currentRequest: WorktreeSidebarProjectRootRequest? = initialRequest
        while let request = currentRequest {
            let worktrees = try? await git.listWorktrees(projectRootPath: request.directory)
            let projectRoot = worktrees?.first?.path
            request.continuation.resume(returning: projectRoot)
            resumeCoalescedRequests(directory: request.directory, projectRoot: projectRoot)
            currentRequest = dequeueRequest()
        }
        isResolving = false
    }

    private func resumeCoalescedRequests(directory: String, projectRoot: String?) {
        let requesterIDs = pendingRequests.compactMap { requesterID, request in
            request.directory == directory ? requesterID : nil
        }
        guard !requesterIDs.isEmpty else { return }
        for requesterID in requesterIDs {
            pendingRequests.removeValue(forKey: requesterID)?
                .continuation.resume(returning: projectRoot)
        }
    }

    private func dequeueRequest() -> WorktreeSidebarProjectRootRequest? {
        while let requesterID = pendingOrder.dequeue() {
            if let request = pendingRequests.removeValue(forKey: requesterID) {
                return request
            }
        }
        return nil
    }
}
