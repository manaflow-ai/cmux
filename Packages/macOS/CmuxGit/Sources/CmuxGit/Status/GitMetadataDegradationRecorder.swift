import Foundation
import os

/// Emits one safety-valve diagnostic per repository for a service lifetime.
final class GitMetadataDegradationRecorder: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.cmuxterm", category: "sidebar-git")

    private let lock = NSLock()
    private var loggedRepositoryRoots: Set<String> = []
    private let sink: @Sendable (String) -> Void

    init(sink: @escaping @Sendable (String) -> Void = { message in
        logger.info("\(message, privacy: .public)")
    }) {
        self.sink = sink
    }

    func record(repositoryRoot: String, reason: GitMetadataDegradationReason) {
        lock.lock()
        let shouldLog = loggedRepositoryRoots.insert(repositoryRoot).inserted
        lock.unlock()
        guard shouldLog else { return }
        sink(
            "workspace.gitStatus.degraded repository=\(repositoryRoot) "
                + "strategy=bounded-git-status untracked=false timeoutSeconds="
                + "\(Int(GitMetadataSafetyLimits.gitStatusWallTime)) reason=\(reason)"
        )
    }
}
