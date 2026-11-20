import CMUXAgentLaunch
import Foundation
import Observation

/// Native restore status stays with the terminal when it moves between containers.
@MainActor
@Observable
final class AgentRestoreRecoveryPresentation {
    enum State: Equatable {
        case checking
        case liveOwner(kind: String, processID: Int, attachInput: String?, attachAvailable: Bool)
        case writerLock(candidates: [CodexWriterProcessInspector.Candidate])
        /// A relaunch that did not start is kept visibly recoverable instead
        /// of becoming an indistinguishable shell.
        case failed(reason: String, recoveryInput: String?)
    }

    var state: State?

    /// Only a failed relaunch is durable; checks and live-owner prompts are
    /// re-derived on the next restore.
    var sessionSnapshot: SessionRestoreRecoverySnapshot? {
        guard case .failed(let reason, let recoveryInput) = state else { return nil }
        return SessionRestoreRecoverySnapshot(reason: reason, recoveryInput: recoveryInput)
    }

    /// Pending admission keeps a persisted failure visible and durable until
    /// admission reaches its own outcome; an app quit while checking must not
    /// drop the recovery input.
    func markCheckingPreservingFailure() {
        if case .failed = state { return }
        state = .checking
    }

    func restore(from snapshot: SessionRestoreRecoverySnapshot?) {
        guard let snapshot else { return }
        state = .failed(reason: snapshot.reason, recoveryInput: snapshot.recoveryInput)
    }
}
