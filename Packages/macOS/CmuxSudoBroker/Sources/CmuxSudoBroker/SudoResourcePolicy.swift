import Foundation

/// Defines one bounded resource envelope for the sudo approval domain.
struct SudoResourcePolicy: Sendable, Equatable {
    static let standard = SudoResourcePolicy()

    let maximumScriptBytes: Int
    let maximumPendingRequestCount: Int
    let maximumPendingScriptBytes: Int
    let maximumActiveRunnerCount: Int
    let artifactRetentionSeconds: TimeInterval
    let maximumArchiveBytes: Int
    let maximumResultBytes: Int
    let maximumAuditBytes: Int
    let retainedAuditBytes: Int
    let privilegedCleanupGraceSeconds: TimeInterval

    init(
        maximumScriptBytes: Int = 256 * 1_024,
        maximumPendingRequestCount: Int = 8,
        maximumPendingScriptBytes: Int = 2 * 1_024 * 1_024,
        maximumActiveRunnerCount: Int = 8,
        artifactRetentionSeconds: TimeInterval = 24 * 60 * 60,
        maximumArchiveBytes: Int = 8 * 1_024 * 1_024,
        maximumResultBytes: Int = 2 * 1_024 * 1_024,
        maximumAuditBytes: Int = 1 * 1_024 * 1_024,
        retainedAuditBytes: Int = 512 * 1_024,
        privilegedCleanupGraceSeconds: TimeInterval = 10
    ) {
        self.maximumScriptBytes = maximumScriptBytes
        self.maximumPendingRequestCount = maximumPendingRequestCount
        self.maximumPendingScriptBytes = maximumPendingScriptBytes
        self.maximumActiveRunnerCount = max(1, maximumActiveRunnerCount)
        self.artifactRetentionSeconds = artifactRetentionSeconds
        self.maximumArchiveBytes = maximumArchiveBytes
        self.maximumResultBytes = maximumResultBytes
        self.maximumAuditBytes = maximumAuditBytes
        self.retainedAuditBytes = retainedAuditBytes
        self.privilegedCleanupGraceSeconds = privilegedCleanupGraceSeconds
    }
}
