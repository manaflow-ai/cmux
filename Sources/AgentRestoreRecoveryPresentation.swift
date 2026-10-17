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

    func restore(from snapshot: SessionRestoreRecoverySnapshot?) {
        guard let snapshot else { return }
        state = .failed(reason: snapshot.reason, recoveryInput: snapshot.recoveryInput)
    }
}
