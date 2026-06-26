import Foundation

// MARK: - Per-directory snapshot task bookkeeping.

extension SidebarGitMetadataService {
    func removeWorkspaceGitSnapshotRequest(for key: WorkspaceGitProbeKey) {
        guard let directory = workspaceGitSnapshotDirectoryByProbeKey.removeValue(forKey: key),
              var requests = workspaceGitSnapshotRequestsByDirectory[directory] else {
            return
        }
        requests.removeAll { $0.probeKey == key }
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

    func trackedPathEventGenerationForSnapshot(directory: String, reason: String) -> UInt64? {
        guard shouldUseTrackedSnapshotCache(reason: reason) else {
            return nil
        }
        return workspaceGitSnapshotCacheGeneration(directory: directory)
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
        for request in workspaceGitSnapshotRequestsByDirectory[directory] ?? [] {
            markWorkspaceGitProbeRerunPending(for: request.probeKey)
        }
    }
}
