internal import CmuxMobileShellModel

extension MobilePairingChecklist {
    func applyingFailure(
        _ category: MobilePairingFailureCategory,
        phase: String,
        message: String? = nil,
        succeededSteps: Set<MobilePairingStep>? = nil
    ) -> MobilePairingChecklist {
        applyingFailure(
            category.pairingStep,
            message: message ?? category.message,
            guidance: category.guidance,
            succeededSteps: succeededSteps ?? category.succeededPairingSteps(phase: phase)
        )
    }

    func applyingOperationalFailure(
        _ category: MobilePairingFailureCategory,
        message: String,
        succeededSteps: Set<MobilePairingStep>? = nil
    ) -> MobilePairingChecklist {
        applyingFailure(category, phase: "operation", message: message, succeededSteps: succeededSteps)
    }
}

extension MobilePairingFailureCategory {
    func succeededPairingSteps(phase: String) -> Set<MobilePairingStep> {
        switch pairingStep {
        case .network:
            return []
        case .authentication:
            return phase == "validation" ? [] : [.network]
        case .trust:
            return []
        }
    }
}
