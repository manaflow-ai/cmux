import Foundation
internal import CmuxGit

// MARK: - Per-directory snapshot task bookkeeping.

extension SidebarGitMetadataService {
    func removeWorkspaceGitSnapshotRequest(for key: WorkspaceGitProbeKey) {
        guard let directory = workspaceGitSnapshotDirectoryByProbeKey.removeValue(forKey: key),
              var requests = workspaceGitSnapshotRequestsByDirectory[directory] else {
            return
        }
        requests.removeValue(forKey: key)
        if requests.isEmpty {
            workspaceGitSnapshotCompletionAuthorityByDirectory.removeValue(forKey: directory)?.invalidate()
            workspaceGitSnapshotRequestsByDirectory.removeValue(forKey: directory)
            workspaceGitSnapshotTaskContextByDirectory.removeValue(forKey: directory)
            workspaceGitSnapshotPendingContextByDirectory.removeValue(forKey: directory)
            if let taskID = workspaceGitSnapshotTaskIDByDirectory.removeValue(forKey: directory) {
                workspaceGitSupersededSnapshotTaskIDs.remove(taskID)
            }
            workspaceGitSnapshotTasksByDirectory.removeValue(forKey: directory)?.cancel()
        } else {
            workspaceGitSnapshotRequestsByDirectory[directory] = requests
        }
    }

    func cancelAllWorkspaceGitSnapshotTasks() {
        workspaceGitSnapshotApplyBatcher.cancel()
        for authority in workspaceGitSnapshotCompletionAuthorityByDirectory.values {
            authority.invalidate()
        }
        workspaceGitSnapshotCompletionAuthorityByDirectory.removeAll()
        for task in workspaceGitSnapshotTasksByDirectory.values {
            task.cancel()
        }
        workspaceGitSnapshotTasksByDirectory.removeAll()
        workspaceGitSnapshotTaskContextByDirectory.removeAll()
        workspaceGitSnapshotPendingContextByDirectory.removeAll()
        workspaceGitSupersededSnapshotTaskIDs.removeAll()
        workspaceGitSnapshotTaskIDByDirectory.removeAll()
        workspaceGitSnapshotRequestsByDirectory.removeAll()
        workspaceGitSnapshotDirectoryByProbeKey.removeAll()
    }

    func snapshotRequestForSnapshot(
        directory: String,
        reason: String,
        fallbackRequest: GitTrackedChangesSnapshotRequest?
    ) -> GitTrackedChangesSnapshotRequest? {
        if let fallbackRequest {
            return fallbackRequest
        }
        guard reason == "filesystemEvent" else {
            advanceWorkspaceGitSnapshotCacheGenerationIfEligible(directory: directory)
            return nil
        }
        let eventID = workspaceGitSnapshotCacheGeneration(directory: directory).map {
            GitTrackedPathEventGeneration(
                namespace: workspaceGitSnapshotCacheNamespace,
                generation: $0
            )
        }
        return .watcherEvent(nil, eventID: eventID)
    }

    func markWorkspaceGitSnapshotRerunPending(directory: String) {
        guard let requests = workspaceGitSnapshotRequestsByDirectory[directory] else {
            return
        }
        for request in requests.values {
            markWorkspaceGitProbeRerunPending(for: request.probeKey)
        }
    }

    func supersedeWorkspaceGitSnapshotTask(
        directory: String,
        with context: WorkspaceGitSnapshotTaskContext
    ) {
        guard workspaceGitSnapshotTaskContextByDirectory[directory] != context,
              let taskID = workspaceGitSnapshotTaskIDByDirectory[directory] else {
            return
        }
        workspaceGitSnapshotPendingContextByDirectory[directory] = context
        workspaceGitSupersededSnapshotTaskIDs.insert(taskID)
        workspaceGitSnapshotCompletionAuthorityByDirectory[directory]?.invalidate()
        markWorkspaceGitSnapshotRerunPending(directory: directory)
    }
}
