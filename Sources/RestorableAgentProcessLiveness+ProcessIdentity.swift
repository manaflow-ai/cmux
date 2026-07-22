import CmuxWorkspaces

extension RestorableAgentProcessLiveness {
    /// Revalidates recorded process generations before applying workspace restore policy.
    func wasRunning(
        fallingBackTo shellActivityState: PanelShellActivityState?,
        recordedProcessIdentities: [Int: AgentPIDProcessIdentity],
        confirmedRuntimeProcessIdentities: Set<AgentPIDProcessIdentity>,
        currentProcessIdentity: (Int) -> AgentPIDProcessIdentity?,
        processPresence: (Int) -> PIDPresence
    ) -> Bool? {
        let processMatches = recordedProcessIdentities.map { processID, recordedIdentity in
            if let currentIdentity = currentProcessIdentity(processID) {
                return currentIdentity == recordedIdentity
                    ? RestorableAgentProcessMatch.matches
                    : RestorableAgentProcessMatch.mismatches
            }
            return processPresence(processID) == .absent ? .mismatches : .unknown
        }
        return revalidated(against: processMatches)
            .resolvedWasRunning(
                fallingBackTo: shellActivityState,
                hasConfirmedRuntimeProcess: !confirmedRuntimeProcessIdentities.isEmpty
            )
    }
}
