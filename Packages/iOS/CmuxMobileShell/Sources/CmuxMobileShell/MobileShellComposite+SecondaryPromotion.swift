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
        instanceTag: String? = nil,
        switchAttemptID: UUID
    ) async -> Bool {
        // Resolve the exact pairing's subscription: the requested tag when given,
        // else any live subscription for the device (legacy device-only callers).
        guard let entry = secondaryMacSubscriptions.first(where: { _, candidate in
            candidate.macDeviceID == macID && (
                instanceTag == nil || MobileMacInstanceTagAuthority.sameStoredAuthority(
                    candidate.authenticatedInstanceTag ?? candidate.storedInstanceTag,
                    instanceTag
                )
            )
        }) else { return false }
        let ownerKey = entry.key
        guard runtime != nil,
              let sub = secondaryMacSubscriptions[ownerKey],
              let pairedMacStore,
              let scope = await currentScopeSnapshot(),
              let current = try? await pairedMacStore.loadAll(
                  stackUserID: scope.userID, teamID: scope.teamID
              ).first(where: {
                  $0.macDeviceID == macID
                      && MobileMacInstanceTagAuthority.sameStoredAuthority(
                          $0.instanceTag,
                          sub.storedInstanceTag
                      )
              }),
              MobileMacInstanceTagAuthority.sameStoredAuthority(
                  current.instanceTag, sub.storedInstanceTag
              ) else {
            secondaryMacSubscriptions[ownerKey]?.cancel()
            secondaryMacSubscriptions[ownerKey] = nil
            return false
        }
        guard let previews = await fetchSecondaryWorkspaces(
                  on: sub.client,
                  macDeviceID: macID,
                  instanceTag: sub.authenticatedInstanceTag ?? sub.storedInstanceTag
              ),
              secondaryMacSubscriptions[ownerKey] === sub,
              isCurrentMacSwitchAttempt(switchAttemptID),
              let refreshed = try? await pairedMacStore.loadAll(
                  stackUserID: scope.userID, teamID: scope.teamID
              ).first(where: {
                  $0.macDeviceID == macID
                      && MobileMacInstanceTagAuthority.sameStoredAuthority(
                          $0.instanceTag,
                          sub.storedInstanceTag
                      )
              }),
              secondaryMacSubscriptions[ownerKey] === sub,
              MobileMacInstanceTagAuthority.sameStoredAuthority(
                  refreshed.instanceTag, sub.storedInstanceTag
              ),
              scope.generation == secondaryAggregationScopeGeneration,
              isCurrentMacSwitchAttempt(switchAttemptID) else {
            if secondaryMacSubscriptions[ownerKey] === sub {
                sub.cancel()
                secondaryMacSubscriptions[ownerKey] = nil
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
        secondaryMacSubscriptions[ownerKey] = nil
        sub.detachKeepingClient()
        let displayName = workspacesByMac[ownerKey]?.displayName
        workspacesByMac[ownerKey] = nil
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
        workspacesByMac[foregroundMacKey] = MacWorkspaceState(
            macDeviceID: macID,
            instanceTag: activeMacInstanceTag,
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
        scheduleForegroundNotificationFeedRefresh(client: sub.client)
        syncSelectedTerminalForWorkspace()
        enqueueActivePairedMacWrite(
            macDeviceID: macID,
            instanceTag: activeMacInstanceTag,
            scope: scope,
            reloadAfterWrite: false
        )
        scheduleSecondaryAggregation()
        return true
    }
}
