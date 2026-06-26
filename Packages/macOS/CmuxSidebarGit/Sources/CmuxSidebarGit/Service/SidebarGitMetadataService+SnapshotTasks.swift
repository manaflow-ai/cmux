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
            workspaceGitSnapshotRequestsByDirectory.removeValue(forKey: directory)
            workspaceGitSnapshotTaskContextByDirectory.removeValue(forKey: directory)
            workspaceGitSnapshotTasksByDirectory.removeValue(forKey: directory)?.cancel()
        } else {
            workspaceGitSnapshotRequestsByDirectory[directory] = requests
        }
    }

    func cancelAllWorkspaceGitSnapshotTasks() {
        for task in workspaceGitSnapshotTasksByDirectory.values {
            task.cancel()
        }
        workspaceGitSnapshotTasksByDirectory.removeAll()
        workspaceGitSnapshotTaskContextByDirectory.removeAll()
        workspaceGitSnapshotRequestsByDirectory.removeAll()
        workspaceGitSnapshotDirectoryByProbeKey.removeAll()
    }

    func trackedPathEventGenerationForSnapshot(
        directory: String,
        reason: String
    ) -> GitTrackedPathEventGeneration? {
        guard shouldUseTrackedSnapshotCache(reason: reason) else {
            return nil
        }
        guard let generation = workspaceGitSnapshotCacheGeneration(directory: directory) else {
            return nil
        }
        return GitTrackedPathEventGeneration(
            namespace: workspaceGitSnapshotCacheNamespace,
            generation: generation
        )
    }

    private func shouldUseTrackedSnapshotCache(reason: String) -> Bool {
        switch reason {
        case "fallbackTimer", "mobileHostDeferred", "rerunPending", "branchChange":
            return false
        default:
            return true
        }
    }

    func markWorkspaceGitSnapshotRerunPending(directory: String) {
        guard let requests = workspaceGitSnapshotRequestsByDirectory[directory] else {
            return
        }
        for request in requests.values {
            markWorkspaceGitProbeRerunPending(for: request.probeKey)
        }
    }
}
