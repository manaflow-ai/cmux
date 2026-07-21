import CmuxWorkspaces

/// Process evidence used to decide whether a restorable agent should resume automatically.
enum RestorableAgentProcessLiveness: Equatable, Hashable, Sendable {
    case running
    case exited
    case unknown

    /// Revalidates cached running evidence, then uses shell activity when no process conclusion exists.
    func wasRunning(
        fallingBackTo shellActivityState: PanelShellActivityState?,
        recordedProcessIdentities: [Int: AgentPIDProcessIdentity],
        confirmedRuntimeProcessIdentities: Set<AgentPIDProcessIdentity>,
        currentProcessIdentity: (Int) -> AgentPIDProcessIdentity?,
        processPresence: (Int) -> PIDPresence
    ) -> Bool? {
        switch revalidated(
            recordedProcessIdentities: recordedProcessIdentities,
            currentProcessIdentity: currentProcessIdentity,
            processPresence: processPresence
        ) {
        case .running:
            return true
        case .exited:
            return !confirmedRuntimeProcessIdentities.isEmpty
        case .unknown:
            switch shellActivityState {
            case .some(.commandRunning):
                return true
            case .some(.promptIdle):
                return false
            case .some(.unknown), .none:
                return nil
            }
        }
    }

    private func revalidated(
        recordedProcessIdentities: [Int: AgentPIDProcessIdentity],
        currentProcessIdentity: (Int) -> AgentPIDProcessIdentity?,
        processPresence: (Int) -> PIDPresence
    ) -> Self {
        guard self == .running else { return self }
        guard !recordedProcessIdentities.isEmpty else { return .unknown }

        var hasUncertainProcess = false
        for (processID, recordedIdentity) in recordedProcessIdentities {
            if let currentIdentity = currentProcessIdentity(processID) {
                if currentIdentity == recordedIdentity {
                    return .running
                }
                // The PID was reused; the recorded process generation exited.
                continue
            }
            if processPresence(processID) != .absent {
                hasUncertainProcess = true
            }
        }
        return hasUncertainProcess ? .unknown : .exited
    }
}
