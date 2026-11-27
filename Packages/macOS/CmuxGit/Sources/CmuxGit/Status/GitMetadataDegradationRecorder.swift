import Foundation
import os

/// Emits one safety-valve diagnostic per repository for a service lifetime.
actor GitMetadataDegradationRecorder {
    private static let logger = Logger(subsystem: "com.cmuxterm", category: "sidebar-git")

    private var loggedRepositoryRoots: Set<String> = []
    private let gitStatusWallTime: TimeInterval
    private let sink: @Sendable (String) -> Void

    init(
        gitStatusWallTime: TimeInterval = GitMetadataSafetyConfiguration().gitStatusWallTime,
        sink: @escaping @Sendable (String) -> Void = { message in
            logger.info("\(message, privacy: .public)")
        }
    ) {
        self.gitStatusWallTime = gitStatusWallTime
        self.sink = sink
    }

    func record(repositoryRoot: String, reason: GitMetadataDegradationReason) {
        let shouldLog = loggedRepositoryRoots.insert(repositoryRoot).inserted
        guard shouldLog else { return }
        sink(
            "workspace.gitStatus.degraded strategy=bounded-git-status "
                + "untracked=false timeoutSeconds="
                + "\(Int(gitStatusWallTime)) reason=\(reason)"
        )
    }
}
