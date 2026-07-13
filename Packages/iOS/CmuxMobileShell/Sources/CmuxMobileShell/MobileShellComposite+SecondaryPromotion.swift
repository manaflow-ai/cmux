import Foundation
import CmuxMobileShellModel
import os

private let secondaryPromotionLog = Logger(
    subsystem: "com.cmuxterm.app",
    category: "MobileSecondaryPromotion"
)

@MainActor
extension MobileShellComposite {
    /// Reuse a live secondary client only while both pre- and post-probe store
    /// reads retain the authority authenticated for that client.
    func promoteSecondaryToForeground(
        _ macID: String,
        switchAttemptID: UUID
    ) async -> Bool {
        guard runtime != nil,
              let sub = secondaryMacSubscriptions[macID],
              let pairedMacStore,
              let scope = await currentScopeSnapshot(),
              let current = try? await pairedMacStore.loadAll(
                  stackUserID: scope.userID, teamID: scope.teamID
              ).first(where: { $0.macDeviceID == macID }),
              MobileMacInstanceTagAuthority.sameStoredAuthority(
                  current.instanceTag, sub.storedInstanceTag
              ) else {
            secondaryMacSubscriptions[macID]?.cancel()
            secondaryMacSubscriptions[macID] = nil
            return false
        }
        guard let previews = await fetchSecondaryWorkspaces(
                  on: sub.client, macDeviceID: macID
              ),
              secondaryMacSubscriptions[macID] === sub,
              isCurrentMacSwitchAttempt(switchAttemptID),
              let refreshed = try? await pairedMacStore.loadAll(
                  stackUserID: scope.userID, teamID: scope.teamID
              ).first(where: { $0.macDeviceID == macID }),
              secondaryMacSubscriptions[macID] === sub,
              MobileMacInstanceTagAuthority.sameStoredAuthority(
                  refreshed.instanceTag, sub.storedInstanceTag
              ),
              scope.generation == secondaryAggregationScopeGeneration,
              isCurrentMacSwitchAttempt(switchAttemptID) else {
            if secondaryMacSubscriptions[macID] === sub {
                sub.cancel()
                secondaryMacSubscriptions[macID] = nil
            }
            return false
        }
        secondaryPromotionLog.info(
            "reusing authenticated secondary client mac=\(macID, privacy: .public)"
        )
        let generation = UUID()
        connectionAttemptGeneration = generation
        connectionGeneration = generation
        cancelRemoteOperationTasks()
        let previousForegroundKey = foregroundMacKey
        secondaryMacSubscriptions[macID] = nil
        sub.detachKeepingClient()
        let displayName = workspacesByMac[macID]?.displayName
        activeTicket = sub.ticket
        activeRoute = sub.route
        activeMacInstanceTag = sub.authenticatedInstanceTag ?? sub.storedInstanceTag
        connectedHostName = placeholderHostName(for: sub.ticket, firstRoute: sub.route)
        replaceRemoteClient(with: sub.client)
        foregroundMacDeviceID = macID
        supportedHostCapabilities = sub.supportedHostCapabilities
        // Promotion reuses the live client without a fresh `mobile.host.status`
        // probe, so the previous foreground Mac's update hint would otherwise
        // survive the switch. Recompute against this Mac's capabilities; the
        // version comes from the just-assigned ticket (nil hides the hint
        // rather than showing the wrong Mac's).
        refreshMacUpdateHint(
            capabilities: sub.supportedHostCapabilities,
            statusMacAppVersion: nil,
            macDeviceID: macID
        )
        workspacesByMac[macID] = MacWorkspaceState(
            macDeviceID: macID,
            displayName: displayName,
            workspaces: previews,
            status: .connected,
            actionCapabilities: sub.actionCapabilities
        )
        dropStalePreviousForeground(previousForegroundKey)
        connectionState = .connected
        markMacConnectionHealthy()
        stopTerminalRefreshPolling()
        startTerminalRefreshPolling()
        syncSelectedTerminalForWorkspace()
        enqueueActivePairedMacWrite(
            macDeviceID: macID, scope: scope, reloadAfterWrite: false
        )
        scheduleSecondaryAggregation()
        return true
    }
}
