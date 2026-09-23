import Foundation

/// A point-in-time probe of one Codex thread writer lock.
public struct CodexWriterLockInspection: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case available
        case active
        case unavailable
    }

    public let state: State
    public let codexHome: String
    public let lockPath: String
    let device: Int32?
    let inode: UInt64?

    public init(
        state: State,
        codexHome: String,
        lockPath: String,
        device: Int32? = nil,
        inode: UInt64? = nil
    ) {
        self.state = state
        self.codexHome = codexHome
        self.lockPath = lockPath
        self.device = device
        self.inode = inode
    }
}

/// The complete evidence used by cmux's explicit recovery command.
public struct CodexWriterRecoveryReport: Equatable, Sendable {
    public let lock: CodexWriterLockInspection
    public let holders: [CodexWriterProcessEvidence]
    public let assessments: [CodexWriterRecoveryAssessment]
    public let processScanIsComplete: Bool

    public var orphanedHolder: CodexWriterProcessEvidence? {
        guard processScanIsComplete, assessments.count == 1 else { return nil }
        return assessments.first { $0.classification == .orphanedAppServer }?.holder
    }

    public init(
        lock: CodexWriterLockInspection,
        holders: [CodexWriterProcessEvidence],
        assessments: [CodexWriterRecoveryAssessment],
        processScanIsComplete: Bool
    ) {
        self.lock = lock
        self.holders = holders
        self.assessments = assessments
        self.processScanIsComplete = processScanIsComplete
    }
}
