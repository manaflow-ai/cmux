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
              ).first(where: {
                  $0.macDeviceID == macID
                      && MobileMacInstanceTagAuthority.sameStoredAuthority(
                          $0.instanceTag,
                          sub.storedInstanceTag
                      )
              }),
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
        let previousForegroundID = foregroundMacDeviceID
        let previousForegroundConnection = previousForegroundID.flatMap {
            connections[$0]
        }
        stopTerminalRefreshPolling()
        cancelRemoteOperationTasks()
        clearPendingTerminalInputForFocusChange()
        // Remove both prior server registrations before changing roles. This is
        // the hard boundary that guarantees only the newly focused Mac can emit
        // terminal bytes or render grids.
        await unsubscribeEventStream(on: sub.client, streamID: sub.streamID)
        if let previousForegroundConnection {
            await unsubscribeTerminalEventStream(
                on: previousForegroundConnection.client
            )
        }
        let previousForegroundKey = foregroundMacKey
        secondaryMacSubscriptions[macID] = nil
        sub.detachKeepingClient()
        let displayName = workspacesByMac[macID]?.displayName
        activeTicket = sub.ticket
        activeRoute = sub.route
        activeMacInstanceTag = sub.authenticatedInstanceTag ?? sub.storedInstanceTag
        connectedHostName = placeholderHostName(for: sub.ticket, firstRoute: sub.route)
        adoptPooledRemoteClient(sub.client)
        foregroundMacDeviceID = macID
        supportedHostCapabilities = sub.supportedHostCapabilities
        connections[macID] = MacConnection(
            macDeviceID: macID,
            ticket: sub.ticket,
            route: sub.route,
            client: sub.client,
            generation: generation,
            displayName: displayName ?? connectedHostName,
            instanceTag: activeMacInstanceTag,
            supportedHostCapabilities: sub.supportedHostCapabilities,
            actionCapabilities: sub.actionCapabilities
        )
        if let previousForegroundID,
           previousForegroundID != macID,
           let previousForegroundConnection {
            let previousControl = SecondaryMacSubscription(
                macDeviceID: previousForegroundID,
                client: previousForegroundConnection.client,
                route: previousForegroundConnection.route,
                ticket: previousForegroundConnection.ticket,
                storedInstanceTag: previousForegroundConnection.instanceTag,
                authenticatedInstanceTag: previousForegroundConnection.instanceTag,
                supportedHostCapabilities:
                    previousForegroundConnection.supportedHostCapabilities,
                actionCapabilities: previousForegroundConnection.actionCapabilities,
                displayName: previousForegroundConnection.displayName
            )
            secondaryMacSubscriptions[previousForegroundID] = previousControl
            startSecondaryEventConsumer(
                previousControl,
                displayName: previousForegroundConnection.displayName
            )
            scheduleSecondaryNotificationFeedRefresh(
                macDeviceID: previousForegroundID,
                client: previousForegroundConnection.client,
                displayName: previousForegroundConnection.displayName
            )
        }
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
        // The old foreground snapshot remains live through its new control
        // connection, so `dropStalePreviousForeground` keeps it in the aggregate.
        dropStalePreviousForeground(previousForegroundKey)
        connectionState = .connected
        markMacConnectionHealthy()
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
