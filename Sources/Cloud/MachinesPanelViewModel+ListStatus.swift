import CmuxCloud
import Foundation

/// What the Machines panel says about the machine-list read.
enum MachineListStatus: Equatable {
    /// The read coordinator reports this Mac offline; nothing has failed.
    case waitingForNetwork
    /// A recovery read is replacing an earlier transient failure.
    case reconnecting
    /// The last settled read failed; Retry or re-authentication applies.
    case failed(MachinesPanelViewModel.CloudListProblem)
}

extension MachinesPanelViewModel {
    enum CloudListProblem: Equatable {
        /// HTTP 401: the Cloud service no longer accepts this session.
        case sessionRejected
        /// HTTP 402: the plan gates Cloud access.
        case requiresPro
        /// Everything else — retrying may help.
        case unreachable
    }

    /// Classify a list failure for ``listProblem``. Pure so tests can pin the
    /// mapping without a live client.
    nonisolated static func classifyListFailure(_ error: VMClientError) -> CloudListProblem {
        switch error {
        case .httpStatus(401, _):
            return .sessionRejected
        case .httpStatus(402, _):
            return .requiresPro
        case .notSignedIn, .sessionRefreshFailed, .backendUnreachable, .httpStatus, .malformedResponse, .lifecycleUnsupported,
             .disabledByManagedPolicy, .cloudMachinesDisabled:
            // A managed policy can race a refresh; keep the generic unreachable state.
            return .unreachable
        }
    }

    /// Derived from the latest settled read, the coordinator's network state,
    /// and whether a recovery read is in flight. Sign-in and plan gates keep
    /// their meaning while a recovery read runs; only a transient failure
    /// becomes "reconnecting", and it clears only when a read succeeds.
    var listStatus: MachineListStatus? {
        if isNetworkOffline { return .waitingForNetwork }
        guard let listProblem else { return nil }
        return isRecoveringList && listProblem == .unreachable ? .reconnecting : .failed(listProblem)
    }
}
