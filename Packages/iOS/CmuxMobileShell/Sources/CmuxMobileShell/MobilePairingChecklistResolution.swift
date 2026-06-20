import CmuxMobileShellModel

extension MobilePairingFailureCategory {
    /// Which pairing gate this failure belongs to. `nil` only for cancellation.
    var stage: MobilePairingStage? {
        switch self {
        case .offline, .hostUnreachable, .listenerNotRunning, .localNetworkBlocked,
             .dnsFailed, .handshakeTimedOut, .connectionDropped, .invalidCode,
             .unrecognizedVersion, .loopbackRejected, .noSupportedRoute, .unknown:
            return .network
        case .authFailed, .ticketExpired:
            return .authentication
        case .accountMismatch, .emailMismatch, .unsupportedRoute:
            return .trust
        case .cancelled:
            return nil
        }
    }

    /// Whether an on-the-wire occurrence proves every earlier gate already passed.
    var clearsPriorGates: Bool {
        switch self {
        case .authFailed, .ticketExpired, .accountMismatch:
            return true
        default:
            return false
        }
    }
}

extension MobilePairingChecklist {
    /// Build the resolved checklist for a failed attempt.
    static func resolving(
        _ category: MobilePairingFailureCategory,
        reachedMac: Bool
    ) -> MobilePairingChecklist {
        guard let failedStage = category.stage else {
            return MobilePairingChecklist(network: .pending, authentication: .pending, trust: .pending)
        }
        let failure = MobilePairingStageStatus.failed(
            message: category.message,
            guidance: category.guidance
        )
        let priorCleared = reachedMac && category.clearsPriorGates
        func status(for stage: MobilePairingStage) -> MobilePairingStageStatus {
            if stage == failedStage { return failure }
            if stage.order < failedStage.order { return priorCleared ? .succeeded : .pending }
            return .pending
        }
        return MobilePairingChecklist(
            network: status(for: .network),
            authentication: status(for: .authentication),
            trust: status(for: .trust)
        )
    }
}
