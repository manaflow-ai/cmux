import Dispatch
import Foundation

extension GitMetadataService {
    /// Runs bounded remote fallback plumbing on the blocking-I/O lane.
    nonisolated func gitRemoteVFallback(repository: ResolvedGitRepository) async -> String? {
        guard await referenceSnapshotLimiter.acquire() else { return nil }
        let cancellationSignal = WorkspaceChangesCancellationSignal()
        let wallTimeLimit = safetyConfiguration.gitStatusWallTime
        let output = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Self.blockingStatusQueue.async {
                    let output = cancellationSignal.withCurrentBinding {
                        let selector = GitReferenceRunnerSelector(wallTimeLimit: wallTimeLimit)
                        let deadline = DispatchTime.now() + wallTimeLimit
                        for runner in selector.candidateRunners.prefix(4) {
                            let now = DispatchTime.now()
                            guard deadline > now else { break }
                            let remaining = Double(deadline.uptimeNanoseconds - now.uptimeNanoseconds)
                                / 1_000_000_000
                            do {
                                let result = try runner.run(
                                    arguments: ["remote", "-v"],
                                    in: URL(fileURLWithPath: repository.workTreeRoot, isDirectory: true),
                                    maximumOutputByteCount: 1 * 1_024 * 1_024,
                                    wallTimeLimit: remaining
                                )
                                if result.exitCode == 0,
                                   !result.standardOutputWasTruncated,
                                   let output = String(data: result.output, encoding: .utf8) {
                                    return output
                                }
                            } catch {
                                continue
                            }
                        }
                        return nil
                    }
                    continuation.resume(returning: output)
                }
            }
        } onCancel: {
            cancellationSignal.cancel()
        }
        await referenceSnapshotLimiter.release()
        return output
    }

    /// Resolves the full reference snapshot for watcher/config consumers.
    nonisolated func gitReferenceSnapshotForConfig(
        repository: ResolvedGitRepository,
        deadline: DispatchTime
    ) async -> GitReferenceSnapshot {
        await gitReferenceSnapshot(repository: repository, deadline: deadline)
    }

    /// Resolves the branch context for config traversal on the blocking-I/O lane.
    nonisolated func gitReferenceBranchContext(
        repository: ResolvedGitRepository
    ) async -> GitConfigBranchContext {
        .resolved((await gitReferenceSnapshot(repository: repository)).branchName)
    }

    /// Resolves refs on the package's bounded blocking-I/O lane.
    ///
    /// - Parameter repository: The already-resolved repository to inspect.
    /// - Returns: A consistent branch, commit, and head-signature snapshot.
    @concurrent
    nonisolated func gitReferenceSnapshot(
        repository: ResolvedGitRepository,
        deadline: DispatchTime? = nil
    ) async -> GitReferenceSnapshot {
        guard deadline.map({ $0 > DispatchTime.now() }) ?? true else {
            return GitReferenceSnapshot(
                checkedOutBranch: .unreadable,
                headSignature: nil,
                currentCommit: nil
            )
        }
        let shouldLimit = referenceReader.requiresGitPlumbing(
            repository: repository,
            deadline: deadline
        )
        guard deadline.map({ $0 > DispatchTime.now() }) ?? true else {
            return GitReferenceSnapshot(
                checkedOutBranch: .unreadable,
                headSignature: nil,
                currentCommit: nil
            )
        }
        let didAcquire = if shouldLimit {
            if let deadline {
                await referenceSnapshotLimiter.acquire(until: deadline)
            } else {
                await referenceSnapshotLimiter.acquire()
            }
        } else {
            true
        }
        guard didAcquire else {
            return GitReferenceSnapshot(
                checkedOutBranch: .unreadable,
                headSignature: nil,
                currentCommit: nil
            )
        }
        let cancellationSignal = WorkspaceChangesCancellationSignal()
        let referenceReader = referenceReader
        let snapshot = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Self.blockingStatusQueue.async {
                    let snapshot = cancellationSignal.withCurrentBinding {
                        guard deadline.map({ $0 > DispatchTime.now() }) ?? true else {
                            return GitReferenceSnapshot(
                                checkedOutBranch: .unreadable,
                                headSignature: nil,
                                currentCommit: nil
                            )
                        }
                        referenceReader.snapshot(repository: repository, deadline: deadline)
                    }
                    continuation.resume(returning: snapshot)
                }
            }
        } onCancel: {
            cancellationSignal.cancel()
        }
        if shouldLimit {
            await referenceSnapshotLimiter.release()
        }
        return snapshot
    }
}
