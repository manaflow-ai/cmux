import Foundation

/// Identifies one agent process generation whose SessionEnd belongs to a
/// cmux initiated hibernation.
struct AgentHibernationSessionEndIntent: Sendable, Equatable {
    let sessionID: String
    let processIdentities: Set<AgentPIDProcessIdentity>
}

extension AgentHibernationController {
    /// Arms preservation before the process signal so SessionEnd cannot race
    /// the panel's post-signal terminating phase.
    func armSessionEndPreservation(
        panelKey: AgentHibernationPanelKey,
        intent: AgentHibernationSessionEndIntent
    ) {
        guard !intent.sessionID.isEmpty, !intent.processIdentities.isEmpty else {
            return
        }
        sessionEndPreservationIntentsByPanel[panelKey] = intent
    }

    /// Removes an intent after a signal batch is rejected or a panel closes.
    func disarmSessionEndPreservation(panelKey: AgentHibernationPanelKey) {
        sessionEndPreservationIntentsByPanel.removeValue(forKey: panelKey)
    }

    /// Retires an old intent once a different process generation owns the panel.
    func disarmSessionEndPreservationIfSuperseded(
        panelKey: AgentHibernationPanelKey,
        processIdentity: AgentPIDProcessIdentity
    ) {
        guard let intent = sessionEndPreservationIntentsByPanel[panelKey],
              !intent.processIdentities.contains(processIdentity) else {
            return
        }
        sessionEndPreservationIntentsByPanel.removeValue(forKey: panelKey)
    }

    /// Returns whether a hook's exact session/process generation belongs to a
    /// pending cmux hibernation.
    func shouldPreserveSessionEnd(
        workspaceID: UUID,
        panelID: UUID,
        sessionID: String,
        processIdentity: AgentPIDProcessIdentity?
    ) -> Bool {
        let key = AgentHibernationPanelKey(workspaceId: workspaceID, panelId: panelID)
        guard let intent = sessionEndPreservationIntentsByPanel[key],
              ManagedAgentSessionIdentity.sessionIDsMatch(
                  kind: RestorableAgentKind.claude.rawValue,
                  lhs: intent.sessionID,
                  rhs: sessionID
              ),
              let processIdentity,
              intent.processIdentities.contains(processIdentity) else {
            return false
        }
        return true
    }

    /// Moves a pending intent with its panel when workspace ownership changes.
    func transferSessionEndPreservation(
        panelID: UUID,
        from sourceWorkspaceID: UUID,
        to destinationWorkspaceID: UUID
    ) {
        guard sourceWorkspaceID != destinationWorkspaceID else { return }
        let sourceKey = AgentHibernationPanelKey(
            workspaceId: sourceWorkspaceID,
            panelId: panelID
        )
        let destinationKey = AgentHibernationPanelKey(
            workspaceId: destinationWorkspaceID,
            panelId: panelID
        )
        guard let intent = sessionEndPreservationIntentsByPanel.removeValue(forKey: sourceKey) else {
            return
        }
        sessionEndPreservationIntentsByPanel[destinationKey] = intent
    }
}
