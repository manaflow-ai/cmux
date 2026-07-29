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
        guard isFocusedConnectionCurrent(connection) else { return false }
        // Publish non-readiness before the unsubscribe await. Cancellation can
        // run while the acknowledgement is being delivered, and restoration
        // must never accept this focus after the host removed its render stream.
        focusedHandoffPreparedGenerations.insert(connection.generation)
        let terminalStopped = await unsubscribeTerminalEventStream(
            on: connection.client
        )
        guard terminalStopped else {
            if isFocusedConnectionCurrent(connection) {
                await connection.client.disconnect()
            } else {
                focusedHandoffPreparedGenerations.remove(
                    connection.generation
                )
            }
            return false
        }
        guard isFocusedConnectionCurrent(connection) else {
            focusedHandoffPreparedGenerations.remove(connection.generation)
            return false
        }
        return true
    }

    /// Commit a prepared focused-client role transition. Registry ownership
    /// moves atomically before the transport role is rebound.
    func commitFocusedConnectionHandoff(
        _ connection: MacConnection,
        terminalStopped: Bool,
        retainAsControl: Bool
    ) async {
        defer {
            focusedHandoffPreparedGenerations.remove(connection.generation)
        }
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
        await installControlConnection(from: connection)
    }

    /// Change a retained focused client to control-only ownership after its
    /// terminal subscription has been removed. The workspace snapshot stays in
    /// `workspacesByMac`, so the aggregate never blinks while roles change.
    func installControlConnection(from connection: MacConnection) async {
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
        focusedHandoffPreparedGenerations.remove(connection.generation)
        await connection.client.updateTransportSessionPurpose(
            .backgroundControl
        )
        // A concurrent switch may have promoted or removed this exact owner
        // while the transport actor applied its role. Its newer role update
        // wins; only the still-current control owner may start maintenance.
        guard secondaryMacSubscriptions[connection.macDeviceID]
                === subscription,
              !subscription.isTransitioningToFocus else {
            return
        }
        startSecondaryControlMaintenance(
            subscription,
            displayName: connection.displayName
        )
    }

    /// Permanently discard one failed promotion candidate before the caller
    /// falls back to a fresh dial. Retirement closes transport admission
    /// synchronously; awaiting disconnect guarantees the old peer session is
    /// gone before a replacement client can compete for it.
    private func retireSecondaryPromotionCandidate(
        _ subscription: SecondaryMacSubscription,
        macDeviceID: String
    ) async {
        guard secondaryMacSubscriptions[macDeviceID] === subscription else {
            return
        }
        subscription.detachKeepingClient()
        subscription.client.retire()
        secondaryMacSubscriptions[macDeviceID] = nil
        markSecondaryMacUnavailable(macDeviceID)
        await subscription.client.disconnect()
    }

    /// Reuse a live secondary client only while both pre- and post-probe store
    /// reads retain the authority authenticated for that client.
    func promoteSecondaryToForeground(
        _ macID: String,
        switchAttemptID: UUID
    ) async -> Bool {
        guard runtime != nil,
              let sub = secondaryMacSubscriptions[macID] else {
            return false
        }
        guard let pairedMacStore,
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
            await retireSecondaryPromotionCandidate(
                sub,
                macDeviceID: macID
            )
            return false
        }
        let preflightWorkspaces = await fetchSecondaryWorkspaces(
            on: sub.client,
            macDeviceID: macID
        )
        guard case .received = preflightWorkspaces,
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
            await retireSecondaryPromotionCandidate(
                sub,
                macDeviceID: macID
            )
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
        if sub.supportedHostCapabilities.contains("events.v1") {
            guard await unsubscribeEventStream(
                on: sub.client,
                streamID: sub.streamID
            ) else {
                await retireSecondaryPromotionCandidate(
                    sub,
                    macDeviceID: macID
                )
                return false
            }
        }
        guard secondaryMacSubscriptions[macID] === sub,
              isCurrentMacSwitchAttempt(switchAttemptID) else {
            await retireSecondaryPromotionCandidate(
                sub,
                macDeviceID: macID
            )
            return false
        }
        await sub.client.updateTransportSessionPurpose(.foregroundControl)
        guard secondaryMacSubscriptions[macID] === sub,
              isCurrentMacSwitchAttempt(switchAttemptID) else {
            await retireSecondaryPromotionCandidate(
                sub,
                macDeviceID: macID
            )
            return false
        }
        stopTerminalRefreshPolling()
        cancelRemoteOperationTasks()
        clearPendingTerminalInputForFocusChange()
        // The old foreground can stay warm only after the Mac proves its
        // terminal registration is gone.
        var previousForegroundCanStayWarm = false
        if let previousForegroundConnection {
            let terminalStopped = await prepareFocusedConnectionForHandoff(
                previousForegroundConnection
            )
            if terminalStopped {
                // Presence, visibility, or account scope may change while the
                // target and old terminal unsubscribe acknowledgements are in
                // flight. Re-read membership immediately before demotion.
                previousForegroundCanStayWarm =
                    await canRetainFocusedConnectionInControlPool(
                        previousForegroundConnection,
                        vacatingControlMacDeviceID: macID
                    )
            }
            if !previousForegroundCanStayWarm,
               isFocusedConnectionCurrent(previousForegroundConnection) {
                await previousForegroundConnection.client.disconnect()
            }
        }
        guard secondaryMacSubscriptions[macID] === sub,
              isCurrentMacSwitchAttempt(switchAttemptID) else {
            await retireSecondaryPromotionCandidate(
                sub,
                macDeviceID: macID
            )
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
                await installControlConnection(
                    from: previousForegroundConnection
                )
            } else {
                removeFocusedConnection(ifMatching: previousForegroundConnection)
            }
        }
        guard secondaryMacSubscriptions[macID] === sub,
              isCurrentMacSwitchAttempt(switchAttemptID) else {
            await retireSecondaryPromotionCandidate(
                sub,
                macDeviceID: macID
            )
            return false
        }
        if let unregisteredPreviousClient,
           unregisteredPreviousClient !== sub.client {
            // Anonymous and legacy foreground sessions have no registry owner
            // to demote. Retire synchronously before replacing `remoteClient`;
            // the asynchronous close removes all of their server registrations.
            unregisteredPreviousClient.retire()
            Task { await unregisteredPreviousClient.disconnect() }
        }
        let liveConnectionGeneration = adoptPooledRemoteClient(sub.client)
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
            generation: liveConnectionGeneration,
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
        // Move selection across the Mac ownership boundary before `activeRoute`
        // restarts mounted terminal lanes. Until this point the aggregate may
        // still preserve the previous Mac's selected workspace and surface IDs.
        selectWorkspaceOnCurrentForegroundMac()
        syncSelectedTerminalForWorkspace()
        activeRoute = sub.route
        connectionState = .connected
        markMacConnectionHealthy()
        // Establish the foreground listener before fetching the snapshot that
        // focus will publish. This closes the control-unsubscribe/terminal-
        // subscribe gap for legacy Macs that have no state-sync cursor repair.
        let subscriptionReadiness =
            MobileTerminalEventSubscriptionReadiness()
        startTerminalRefreshPolling(
            subscriptionReadiness: subscriptionReadiness,
            recoversConnectionOnSubscriptionFailure: false
        )
        let foregroundEventsReady = await subscriptionReadiness.wait()
        guard isCurrentMacSwitchAttempt(switchAttemptID),
              remoteClient === sub.client,
              foregroundMacDeviceID == macID else {
            return false
        }
        guard foregroundEventsReady else {
            stopTerminalRefreshPolling()
            if let promotedConnection = connections[macID] {
                invalidateFocusedConnectionAfterAbortedHandoff(
                    promotedConnection
                )
            }
            return false
        }
        let snapshotEventGeneration = workspaceListEventGeneration
        let snapshotStateRevision = foregroundWorkspaceStateRevision
        let authoritativeWorkspaceAttempt = await fetchSecondaryWorkspaces(
            on: sub.client,
            macDeviceID: macID
        )
        guard isCurrentMacSwitchAttempt(switchAttemptID),
              remoteClient === sub.client,
              foregroundMacDeviceID == macID else {
            return false
        }
        guard case let .received(authoritativePreviews) =
                authoritativeWorkspaceAttempt else {
            stopTerminalRefreshPolling()
            if let promotedConnection = connections[macID] {
                invalidateFocusedConnectionAfterAbortedHandoff(
                    promotedConnection
                )
            }
            return false
        }
        // A workspace event that raced the fetch already owns a fresh
        // foreground refetch. Never overwrite its result with this older
        // response.
        if workspaceListEventGeneration == snapshotEventGeneration,
           foregroundWorkspaceStateRevision == snapshotStateRevision {
            workspacesByMac[macID] = MacWorkspaceState(
                macDeviceID: macID,
                displayName: displayName,
                workspaces: authoritativePreviews,
                status: .connected,
                actionCapabilities: sub.actionCapabilities
            )
            foregroundWorkspaceStateRevision &+= 1
        }
        selectWorkspaceOnCurrentForegroundMac()
        // The old foreground snapshot remains live through its new control
        // connection, so `dropStalePreviousForeground` keeps it in the aggregate.
        dropStalePreviousForeground(previousForegroundKey)
        scheduleForegroundNotificationFeedRefresh(client: sub.client)
        syncSelectedTerminalForWorkspace()
        enqueueActivePairedMacWrite(
            macDeviceID: macID,
            instanceTag: sub.storedInstanceTag,
            scope: scope,
            reloadAfterWrite: false
        )
        scheduleSecondaryAggregation()
        return true
    }
}
