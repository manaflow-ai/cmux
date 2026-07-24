internal import Darwin

extension WorkspaceChangesService {
    /// Pins the SE-0338 executor-hop contract that keeps Git off the caller's actor.
    nonisolated func executionHopsOffCallersThread() async -> Bool {
        pthread_main_np() == 0
    }

    nonisolated func changedFilesValue(
        from snapshot: WorkspaceChangesSnapshot
    ) -> WorkspaceChangedFiles {
        WorkspaceChangedFiles(
            isRepository: true,
            repoRoot: snapshot.scope.repoRoot,
            branch: snapshot.scope.branch,
            baseRef: snapshot.scope.baseRef,
            files: snapshot.files,
            filesChanged: snapshot.totalFileCount,
            additions: snapshot.additions,
            deletions: snapshot.deletions,
            truncated: snapshot.truncated || snapshot.totalFileCount > snapshot.files.count
        )
    }

    nonisolated func fileDiffValue(
        file: WorkspaceChangedFile,
        unifiedDiff: String,
        truncated: Bool,
        totalLineCount: Int?,
        contentFingerprint: String?
    ) -> WorkspaceFileDiff {
        WorkspaceFileDiff(
            path: file.path,
            oldPath: file.oldPath,
            status: file.status,
            isBinary: file.isBinary,
            additions: file.additions,
            deletions: file.deletions,
            unifiedDiff: unifiedDiff,
            truncated: truncated,
            totalLineCount: totalLineCount,
            contentFingerprint: contentFingerprint
        )
    }
}
