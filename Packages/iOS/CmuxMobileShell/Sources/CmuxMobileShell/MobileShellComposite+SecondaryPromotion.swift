import Foundation
import CmuxMobileShellModel
import os

nonisolated private let secondaryPromotionLog = Logger(
    subsystem: "com.cmuxterm.app",
    category: "MobileSecondaryPromotion"
)

@MainActor
extension MobileShellComposite {
    /// Stop a focused client's terminal lane before changing its role. This
    /// suspending phase deliberately does not publish a new role: the caller
    /// must revalidate switch ownership after the acknowledgement arrives.
    func prepareFocusedConnectionForHandoff(
        _ connection: MacConnection
    ) async -> Bool {
        let terminalStopped = await unsubscribeTerminalEventStream(
            on: connection.client
        )
        guard terminalStopped else {
            if isFocusedConnectionCurrent(connection) {
                await connection.client.disconnect()
            }
            return false
        }
        return isFocusedConnectionCurrent(connection)
    }

    /// Commit a prepared focused-client role transition without suspension.
    /// A successful unsubscribe is the only path that may retain the client.
    func commitFocusedConnectionHandoff(
        _ connection: MacConnection,
        terminalStopped: Bool,
        retainAsControl: Bool
    ) {
        guard terminalStopped else {
            removeFocusedConnection(ifMatching: connection)
            return
        }
        guard retainAsControl else {
            guard removeFocusedConnection(ifMatching: connection) else {
                return
            }
            connection.client.retire()
            Task { await connection.client.disconnect() }
            return
        }
        installControlConnection(from: connection)
    }

    /// Change a retained focused client to control-only ownership after its
    /// terminal subscription has been removed. The workspace snapshot stays in
    /// `workspacesByMac`, so the aggregate never blinks while roles change.
    func installControlConnection(from connection: MacConnection) {
        guard multiMacAggregationEnabled else {
            removeFocusedConnection(ifMatching: connection)
            connection.client.retire()
            Task { await connection.client.disconnect() }
            return
        }
        let subscription = SecondaryMacSubscription(
            macDeviceID: connection.macDeviceID,
            client: connection.client,
            route: connection.route,
            ticket: connection.ticket,
            storedInstanceTag: connection.instanceTag,
            authenticatedInstanceTag: connection.instanceTag,
            supportedHostCapabilities: connection.supportedHostCapabilities,
            actionCapabilities: connection.actionCapabilities,
            displayName: connection.displayName
        )
        guard transitionFocusedConnectionToControl(
            subscription,
            replacing: connection
        ) else {
            // A newer focus generation may intentionally reuse this client.
            // Never let the stale demotion disconnect its current owner.
            if !registryOwnsClient(of: connection) {
                subscription.cancel()
            }
            return
        }
        startSecondaryEventConsumer(
            subscription,
            displayName: connection.displayName
        )
        scheduleSecondaryNotificationFeedRefresh(
            macDeviceID: connection.macDeviceID,
            client: connection.client,
            displayName: connection.displayName
        )
    }

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
            if let current = secondaryMacSubscriptions[macID] {
                current.cancel()
                secondaryMacSubscriptions[macID] = nil
            }
            return false
        }
        guard await fetchSecondaryWorkspaces(
                  on: sub.client, macDeviceID: macID
              ) != nil,
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
        let unregisteredPreviousClient = previousForegroundConnection == nil
            ? remoteClient
            : nil
        let previousForegroundIsPoolEligible = if let previousForegroundConnection {
            await canRetainFocusedConnectionInControlPool(
                previousForegroundConnection
            )
        } else {
            false
        }
        guard isCurrentMacSwitchAttempt(switchAttemptID) else { return false }
        guard await prepareSecondarySubscriptionForPromotion(
            sub,
            macDeviceID: macID
        ) else {
            return false
        }
        guard secondaryMacSubscriptions[macID] === sub,
              isCurrentMacSwitchAttempt(switchAttemptID) else {
            await resumeSecondarySubscriptionAfterAbortedPromotion(
                sub,
                macDeviceID: macID
            )
            return false
        }
        // Remove the target's control registration before disturbing the live
        // foreground. If this acknowledgement fails, its client is discarded
        // and the ordinary fresh-dial switch path can proceed.
        guard await unsubscribeEventStream(
            on: sub.client,
            streamID: sub.streamID
        ) else {
            sub.cancel()
            if secondaryMacSubscriptions[macID] === sub {
                secondaryMacSubscriptions[macID] = nil
            }
            return false
        }
        guard secondaryMacSubscriptions[macID] === sub,
              isCurrentMacSwitchAttempt(switchAttemptID) else {
            sub.cancel()
            if secondaryMacSubscriptions[macID] === sub {
                secondaryMacSubscriptions[macID] = nil
            }
            return false
        }
        stopTerminalRefreshPolling()
        cancelRemoteOperationTasks()
        clearPendingTerminalInputForFocusChange()
        // The old foreground can stay warm only after the Mac proves its
        // terminal registration is gone.
        var previousForegroundCanStayWarm = false
        if let previousForegroundConnection {
            let terminalStopped = await unsubscribeTerminalEventStream(
                on: previousForegroundConnection.client
            )
            previousForegroundCanStayWarm = terminalStopped
                && previousForegroundIsPoolEligible
            if !previousForegroundCanStayWarm,
               isFocusedConnectionCurrent(previousForegroundConnection) {
                await previousForegroundConnection.client.disconnect()
            }
        }
        guard secondaryMacSubscriptions[macID] === sub,
              isCurrentMacSwitchAttempt(switchAttemptID) else {
            sub.cancel()
            if secondaryMacSubscriptions[macID] === sub {
                secondaryMacSubscriptions[macID] = nil
            }
            if let previousForegroundConnection {
                invalidateFocusedConnectionAfterAbortedHandoff(
                    previousForegroundConnection
                )
            }
            return false
        }
        let previousForegroundKey = foregroundMacKey
        sub.detachKeepingClient()
        let displayName = workspacesByMac[macID]?.displayName
        if let previousForegroundID,
           previousForegroundID != macID,
           let previousForegroundConnection {
            if previousForegroundCanStayWarm {
                installControlConnection(from: previousForegroundConnection)
            } else {
                removeFocusedConnection(ifMatching: previousForegroundConnection)
            }
        }
        if let unregisteredPreviousClient,
           unregisteredPreviousClient !== sub.client {
            // Anonymous and legacy foreground sessions have no registry owner
            // to demote. Retire synchronously before replacing `remoteClient`;
            // the asynchronous close removes all of their server registrations.
            unregisteredPreviousClient.retire()
            Task { await unregisteredPreviousClient.disconnect() }
        }
        adoptPooledRemoteClient(sub.client)
        activeTicket = sub.ticket
        activeMacInstanceTag = sub.authenticatedInstanceTag ?? sub.storedInstanceTag
        connectedHostName = placeholderHostName(for: sub.ticket, firstRoute: sub.route)
        foregroundMacDeviceID = macID
        supportedHostCapabilities = sub.supportedHostCapabilities
        installFocusedConnection(MacConnection(
            macDeviceID: macID,
            ticket: sub.ticket,
            route: sub.route,
            client: sub.client,
            generation: generation,
            displayName: displayName ?? connectedHostName,
            instanceTag: activeMacInstanceTag,
            supportedHostCapabilities: sub.supportedHostCapabilities,
            actionCapabilities: sub.actionCapabilities
        ))
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
        activeRoute = sub.route
        connectionState = .connected
        markMacConnectionHealthy()
        // Establish the foreground listener before fetching the snapshot that
        // focus will publish. This closes the control-unsubscribe/terminal-
        // subscribe gap for legacy Macs that have no state-sync cursor repair.
        let subscriptionReadiness =
            MobileTerminalEventSubscriptionReadiness()
        startTerminalRefreshPolling(
            subscriptionReadiness: subscriptionReadiness
        )
        let foregroundEventsReady = await subscriptionReadiness.wait()
        guard isCurrentMacSwitchAttempt(switchAttemptID),
              remoteClient === sub.client,
              foregroundMacDeviceID == macID else {
            return false
        }
        if foregroundEventsReady {
            let snapshotEventGeneration = workspaceListEventGeneration
            let authoritativePreviews = await fetchSecondaryWorkspaces(
                on: sub.client,
                macDeviceID: macID
            )
            guard isCurrentMacSwitchAttempt(switchAttemptID),
                  remoteClient === sub.client,
                  foregroundMacDeviceID == macID else {
                return false
            }
            // A workspace event that raced the fetch already owns a fresh
            // foreground refetch. Never overwrite its result with this older
            // response.
            if workspaceListEventGeneration == snapshotEventGeneration,
               let authoritativePreviews {
                workspacesByMac[macID] = MacWorkspaceState(
                    macDeviceID: macID,
                    displayName: displayName,
                    workspaces: authoritativePreviews,
                    status: .connected,
                    actionCapabilities: sub.actionCapabilities
                )
            }
        }
        selectWorkspaceOnCurrentForegroundMac()
        // The old foreground snapshot remains live through its new control
        // connection, so `dropStalePreviousForeground` keeps it in the aggregate.
        dropStalePreviousForeground(previousForegroundKey)
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
