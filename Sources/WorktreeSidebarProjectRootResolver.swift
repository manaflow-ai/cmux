import Foundation

/// Serial resolver with one Git listing in flight and one pending request per workspace.
actor WorktreeSidebarProjectRootResolver {
    private struct Request: Sendable {
        let requesterID: UUID
        let directory: String
        let continuation: CheckedContinuation<String?, Never>
    }

    private let git: any WorktreeSidebarGitOperating
    private var isResolving = false
    private var pendingOrder: [UUID] = []
    private var pendingRequests: [UUID: Request] = [:]

    init(git: (any WorktreeSidebarGitOperating)? = nil) {
        self.git = git ?? WorktreeSidebarGitService()
    }

    func projectRoot(
        onDiskFor directory: String,
        requesterID: UUID = UUID()
    ) async -> String? {
        await withCheckedContinuation { continuation in
            enqueue(Request(
                requesterID: requesterID,
                directory: directory,
                continuation: continuation
            ))
        }
    }

    private func enqueue(_ request: Request) {
        guard isResolving else {
            isResolving = true
            Task { await resolve(request) }
            return
        }
        if let previous = pendingRequests.updateValue(request, forKey: request.requesterID) {
            previous.continuation.resume(returning: nil)
        } else {
            pendingOrder.append(request.requesterID)
        }
    }

    private func resolve(_ initialRequest: Request) async {
        var currentRequest: Request? = initialRequest
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
        let requesterIDs = pendingOrder.filter { pendingRequests[$0]?.directory == directory }
        guard !requesterIDs.isEmpty else { return }
        let requesterIDSet = Set(requesterIDs)
        pendingOrder.removeAll { requesterIDSet.contains($0) }
        for requesterID in requesterIDs {
            pendingRequests.removeValue(forKey: requesterID)?
                .continuation.resume(returning: projectRoot)
        }
    }

    private func dequeueRequest() -> Request? {
        while let requesterID = pendingOrder.popLast() {
            if let request = pendingRequests.removeValue(forKey: requesterID) {
                return request
            }
        }
        return nil
    }
}
