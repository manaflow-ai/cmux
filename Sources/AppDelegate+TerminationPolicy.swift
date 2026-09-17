import Foundation

extension AppDelegate {
    enum TerminateCleanupPhase: Equatable, Sendable {
        case ownedRuntimeCleanup
        case freshSnapshot
        /// The durable snapshot must not be replaced after agents receive signals.
        case agentProcesses
    }

    enum TerminateCleanupDeadlineDisposition: Equatable, Sendable {
        case persistCachedSnapshotAndTerminate
        case terminateWithSavedSnapshot
        case cancelTerminationAfterRuntimeCleanupFailure
    }

    nonisolated static func terminateCleanupDeadlineDisposition(
        phase: TerminateCleanupPhase?,
        hasOwnedRuntimeCleanup: Bool
    ) -> TerminateCleanupDeadlineDisposition {
        if phase == .agentProcesses { return .terminateWithSavedSnapshot }
        if phase == .freshSnapshot || !hasOwnedRuntimeCleanup {
            return .persistCachedSnapshotAndTerminate
        }
        return .cancelTerminationAfterRuntimeCleanupFailure
    }
}
