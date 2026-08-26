internal import CMUXMobileCore
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
        guard await prepareTerminalSubscriptionHandoff(
            on: connection.client
        ) else {
            if isFocusedConnectionCurrent(connection) {
                connection.client.retire()
                await connection.client.disconnect()
            }
            return false
        }
        let terminalStopped = await unsubscribeTerminalEventStream(
            on: connection.client
        )
        guard terminalStopped else {
            if isFocusedConnectionCurrent(connection) {
                connection.client.retire()
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
            removeControlCapability(ifMatching: connection)
            removeFocusedConnection(ifMatching: connection)
            return
        }
        guard retainAsControl else {
            removeControlCapability(ifMatching: connection)
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
            removeControlCapability(ifMatching: connection)
            removeFocusedConnection(ifMatching: connection)
            connection.client.retire()
            Task { await connection.client.disconnect() }
            return
        }
        let existing = secondaryMacSubscriptions[connection.ownerKey]
        let subscription: SecondaryMacSubscription
        let needsActivation: Bool
        if let existing, existing.client === connection.client {
            subscription = existing
            needsActivation = false
        } else {
            subscription = makeControlSubscription(from: connection)
            needsActivation = true
        }
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
        if needsActivation {
            await activateDemotedControlConnection(
                subscription,
                from: connection
            )
        } else {
            focusedHandoffPreparedGenerations.remove(connection.generation)
            await synchronizeTransportSessionPurpose(connection.client)
            // While focused, this peer's feed lived under the bare device key
            // and was removed on demotion. The reuse branch skips activation
            // catch-up, so reseed the pairing-keyed snapshot explicitly.
            scheduleSecondaryNotificationFeedRefresh(
                macDeviceID: subscription.ownerKey.pairingID,
                client: subscription.client,
                displayName: subscription.displayName
            )
        }
    }

    func makeControlSubscription(
        from connection: MacConnection
    ) -> SecondaryMacSubscription {
        SecondaryMacSubscription(
            macDeviceID: connection.macDeviceID,
            client: connection.client,
            route: connection.route,
            ticket: connection.ticket,
            storedInstanceTag: connection.storedInstanceTag,
            authenticatedInstanceTag: connection.authenticatedInstanceTag,
            supportedHostCapabilities: connection.supportedHostCapabilities,
            actionCapabilities: connection.actionCapabilities,
            displayName: connection.displayName
        )
    }

    func activateDemotedControlConnection(
        _ subscription: SecondaryMacSubscription,
        from connection: MacConnection
    ) async {
        focusedHandoffPreparedGenerations.remove(connection.generation)
        guard secondaryMacSubscriptions[subscription.ownerKey]
                === subscription,
              !subscription.isTransitioningToFocus else {
            return
        }
        await synchronizeTransportSessionPurpose(connection.client)
        // A concurrent switch may have promoted or removed this exact owner
        // while the transport actor applied its role. Its newer role update
        // wins; only the still-current control owner may start maintenance.
        guard secondaryMacSubscriptions[subscription.ownerKey]
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
    func retireSecondaryPromotionCandidate(
        _ subscription: SecondaryMacSubscription
    ) async {
        guard beginSecondaryMacDrainReservation(subscription) else {
            return
        }
        let operation = secondaryMacTransportDrainOperation(subscription)
        if await operation.wait(
            nanoseconds: connectionHandoffDrainTimeoutNanoseconds
        ) {
            finishRetiredSecondaryPromotionCandidate(subscription)
        }
    }

    /// Start or reuse the reservation's exact physical transport close. The
    /// completion owner is also installed once, so repeated same-Mac switches
    /// only wait on this operation instead of accumulating cleanup tasks.
    func secondaryMacTransportDrainOperation(
        _ subscription: SecondaryMacSubscription
    ) -> SecondaryMacTransportDrainOperation {
        if let operation = subscription.transportDrainOperation {
            return operation
        }
        let client = subscription.client
        let task = Task {
            await client.disconnectAndWaitForTransportDrain()
        }
        let operation = SecondaryMacTransportDrainOperation(task: task)
        subscription.transportDrainOperation = operation
        operation.completionTask = Task { @MainActor [
            weak self,
            weak subscription,
            weak operation
        ] in
            await task.value
            guard let self, let subscription, let operation,
                  subscription.transportDrainOperation === operation else {
                return
            }
            operation.finish()
            operation.completionTask = nil
            self.finishRetiredSecondaryPromotionCandidate(subscription)
        }
        return operation
    }

    @discardableResult
    func finishRetiredSecondaryPromotionCandidate(
        _ subscription: SecondaryMacSubscription,
        forceRemovalDuringMacSwitch: Bool = false
    ) -> Bool {
        let reservationKey = subscription.ownerKey
        guard secondaryMacDrainReservations[reservationKey]
                === subscription else {
            return false
        }
        subscription.hasCompletedTransportDrain = true
        guard subscription.transportDrainReservationHolders.isEmpty else {
            return false
        }
        guard forceRemovalDuringMacSwitch || macSwitchAttemptID == nil else {
            return false
        }
        secondaryMacDrainReservations[reservationKey] = nil
        markSecondaryMacUnavailableIfUnowned(reservationKey)
        switch subscription.postDrainAction {
        case .none:
            break
        case .refreshPresence:
            scheduleSecondaryPresenceAggregation(
                forMacDeviceID: subscription.macDeviceID
            )
        case .retry:
            scheduleSecondaryAggregationRetry(
                macDeviceIDs: [subscription.macDeviceID]
            )
        }
        subscription.postDrainAction = .none
        return true
    }

    func secondaryMacDrainReservation(
        for ownerKey: MacPairingKey
    ) -> SecondaryMacSubscription? {
        secondaryMacDrainReservations[ownerKey]
    }

    /// Any still-draining retired owner on the given physical device. Fresh
    /// dials block on this device-wide check because a replaced pairing (a
    /// retagged build) reuses the SAME physical peer session: dialing before
    /// the old transport drain completes cannot acquire the peer session.
    func secondaryMacDrainReservation(
        onDeviceOf ownerKey: MacPairingKey
    ) -> SecondaryMacSubscription? {
        if let exact = secondaryMacDrainReservations[ownerKey] { return exact }
        return secondaryMacDrainReservations.first {
            $0.key.canonicalMacDeviceID == ownerKey.canonicalMacDeviceID
        }?.value
    }

    @discardableResult
    func beginSecondaryMacDrainReservation(
        _ subscription: SecondaryMacSubscription,
        postDrainAction: SecondaryMacPostDrainAction = .refreshPresence
    ) -> Bool {
        let reservationKey = subscription.ownerKey
        guard secondaryMacSubscriptions[reservationKey] === subscription else {
            return false
        }
        guard secondaryMacDrainReservations[reservationKey] == nil else {
            return false
        }
        subscription.isTransitioningToFocus = true
        subscription.detachKeepingClient()
        subscription.client.retire()
        subscription.hasCompletedTransportDrain = false
        subscription.transportDrainOperation = nil
        subscription.transportDrainReservationHolders = []
        subscription.postDrainAction = postDrainAction
        secondaryMacSubscriptions[reservationKey] = nil
        secondaryMacDrainReservations[reservationKey] = subscription
        markSecondaryMacUnavailable(reservationKey)
        _ = secondaryMacTransportDrainOperation(subscription)
        return true
    }

    func retireSecondaryControlOwner(
        _ subscription: SecondaryMacSubscription,
        shouldRetry: Bool
    ) async {
        if removeFailedControlCapabilityFromFocusedSession(subscription) {
            return
        }
        guard beginSecondaryMacDrainReservation(
            subscription,
            postDrainAction: shouldRetry ? .retry : .none
        ) else {
            return
        }
        let operation = secondaryMacTransportDrainOperation(subscription)
        if await operation.wait(
            nanoseconds: connectionHandoffDrainTimeoutNanoseconds
        ) {
            finishRetiredSecondaryPromotionCandidate(subscription)
            return
        }
    }

    /// A control consumer can fail after its peer has acquired focus. Remove
    /// only that failed capability; foreground recovery continues owning the
    /// shared client, and the next demotion can install fresh control work.
    private func removeFailedControlCapabilityFromFocusedSession(
        _ subscription: SecondaryMacSubscription
    ) -> Bool {
        let ownerKey = subscription.ownerKey
        guard secondaryMacSubscriptions[ownerKey] === subscription,
              subscription.client === remoteClient,
              let focused = connections[ownerKey],
              focused.client === subscription.client else {
            return false
        }
        cancelSecondaryControlReassertion(ifOwnedBy: subscription)
        subscription.detachKeepingClient()
        subscription.hasActivatedControlStream = false
        secondaryMacSubscriptions[ownerKey] = nil
        return true
    }

    func finishCompletedSecondaryMacDrainReservations() {
        let completed = secondaryMacDrainReservations.values.filter(
            \.hasCompletedTransportDrain
        )
        for subscription in completed {
            finishRetiredSecondaryPromotionCandidate(subscription)
        }
    }

    /// A pooled client can fail after it has already become the focused owner.
    /// Remove its public/actionable role, retain a same-Mac reservation, and
    /// bound the switch-visible drain before the caller enters fresh fallback.
    func retirePromotedConnectionForFreshDial(
        _ connection: MacConnection,
        subscription: SecondaryMacSubscription,
        switchAttemptID: UUID
    ) async {
        let reservationKey = subscription.ownerKey
        let isStillFocused = isFocusedConnectionCurrent(connection)
        if !isStillFocused {
            guard isCurrentMacSwitchAttempt(switchAttemptID),
                  secondaryMacDrainReservations[reservationKey] == nil,
                  !liveMacConnections.contains(where: {
                      $0.id == reservationKey.pairingID
                  }) else {
                return
            }
        }
        guard secondaryMacDrainReservations[reservationKey] == nil else {
            return
        }
        subscription.isTransitioningToFocus = true
        subscription.detachKeepingClient()
        subscription.client.retire()
        subscription.hasCompletedTransportDrain = false
        subscription.transportDrainOperation = nil
        subscription.transportDrainReservationHolders = []
        subscription.postDrainAction = .refreshPresence
        secondaryMacDrainReservations[reservationKey] = subscription
        if isStillFocused {
            invalidateFocusedConnectionAfterAbortedHandoff(connection)
        } else {
            markSecondaryMacUnavailable(reservationKey)
        }

        let operation = secondaryMacTransportDrainOperation(subscription)
        if await operation.wait(
            nanoseconds: connectionHandoffDrainTimeoutNanoseconds
        ) {
            finishRetiredSecondaryPromotionCandidate(subscription)
            return
        }
    }

    /// Resolve which control-pool pairing a switch to `(macDeviceID,
    /// instanceTag)` may promote. A tagged request promotes only the exact
    /// pairing. A device-only request (legacy callers with no tag) promotes
    /// only when it is unambiguous: with two sibling builds live or stored, an
    /// arbitrary pick would route input to the wrong instance, so fail closed
    /// and let the store-resolved dial pick the authoritative pairing.
    func resolvePromotableSecondaryOwnerKey(
        macDeviceID: String,
        instanceTag: String?
    ) -> MacPairingKey? {
        let candidates = secondaryMacSubscriptions.filter { _, candidate in
            candidate.ownerKey.isOnDevice(macDeviceID) && (
                instanceTag == nil
                    || macInstanceTagAuthority.sameStoredAuthority(
                        candidate.storedInstanceTag,
                        instanceTag
                    )
            )
        }
        guard candidates.count == 1, let entry = candidates.first else {
            return nil
        }
        if instanceTag == nil {
            // A device-only request is unambiguous only when the device has one
            // stored pairing at all: "the only LIVE sibling" may still be the
            // wrong one when the intended sibling is merely offline.
            let storedSiblings = pairedMacsForIdentityMatching.filter {
                cmxCanonicalDeviceID($0.macDeviceID)
                    == cmxCanonicalDeviceID(macDeviceID)
            }
            guard entry.key.normalizedInstanceTag == nil,
                  storedSiblings.count == 1,
                  storedSiblings[0].instanceTag == nil else { return nil }
        }
        return entry.key
    }

    /// Reuse a live secondary client only while both pre- and post-probe store
    /// reads retain the authority authenticated for that client.
    func promoteSecondaryToForeground(
        _ ownerKey: MacPairingKey,
        switchAttemptID: UUID
    ) async -> Bool {
        switch await promoteSecondaryToForegroundOutcome(
            ownerKey,
            switchAttemptID: switchAttemptID
        ) {
        case .promoted:
            return true
        case .unavailable, .transientFailure:
            return false
        }
    }

    func promoteSecondaryToForegroundOutcome(
        _ ownerKey: MacPairingKey,
        switchAttemptID: UUID
    ) async -> SecondaryPromotionOutcome {
        guard runtime != nil,
              let sub = secondaryMacSubscriptions[ownerKey] else {
            return .unavailable
        }
        // The store authority reads below match rows by the subscription's
        // original device-id spelling, which is what the store accepted when
        // this control connection was established.
        let macID = sub.macDeviceID
        let priorSecondaryGroups = workspacesByMac[ownerKey]?.groups ?? []
        guard let scope = await currentScopeSnapshot() else {
            await retireSecondaryPromotionCandidate(sub)
            return .unavailable
        }
        switch await readSecondaryStoredAuthority(
            macDeviceID: macID,
            storedInstanceTag: sub.storedInstanceTag,
            scope: scope
        ) {
        case .authorized:
            break
        case .revoked:
            await retireSecondaryPromotionCandidate(sub)
            return .unavailable
        case .transientFailure:
            scheduleSecondaryAggregationRetry(macDeviceIDs: [macID])
            return .transientFailure
        }
        let preflightWorkspaces = await fetchSecondaryWorkspaces(
            on: sub.client,
            macDeviceID: macID
        )
        guard case .received = preflightWorkspaces,
              secondaryMacSubscriptions[ownerKey] === sub,
              isCurrentMacSwitchAttempt(switchAttemptID) else {
            await retireSecondaryPromotionCandidate(sub)
            return .unavailable
        }
        switch await readSecondaryStoredAuthority(
            macDeviceID: macID,
            storedInstanceTag: sub.storedInstanceTag,
            scope: scope
        ) {
        case .authorized:
            break
        case .revoked:
            await retireSecondaryPromotionCandidate(sub)
            return .unavailable
        case .transientFailure:
            scheduleSecondaryAggregationRetry(macDeviceIDs: [macID])
            return .transientFailure
        }
        guard
              secondaryMacSubscriptions[ownerKey] === sub,
              scope.generation == secondaryAggregationScopeGeneration,
              isCurrentMacSwitchAttempt(switchAttemptID) else {
            await retireSecondaryPromotionCandidate(sub)
            return .unavailable
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
        guard isCurrentMacSwitchAttempt(switchAttemptID) else {
            return .unavailable
        }
        guard await prepareSecondarySubscriptionForPromotion(sub) else {
            return .unavailable
        }
        guard secondaryMacSubscriptions[ownerKey] === sub,
              isCurrentMacSwitchAttempt(switchAttemptID) else {
            await resumeSecondarySubscriptionAfterAbortedPromotion(sub)
            return .unavailable
        }
        // Remove the target's control registration before disturbing the live
        // foreground. If this acknowledgement fails, its client is discarded
        // and the ordinary fresh-dial switch path can proceed.
        if sub.supportedHostCapabilities.contains("events.v1") {
            guard await unsubscribeEventStream(
                on: sub.client,
                streamID: sub.streamID
            ) else {
                await retireSecondaryPromotionCandidate(sub)
                return .unavailable
            }
        }
        guard secondaryMacSubscriptions[ownerKey] === sub,
              isCurrentMacSwitchAttempt(switchAttemptID) else {
            await retireSecondaryPromotionCandidate(sub)
            return .unavailable
        }
        await sub.client.updateTransportSessionPurpose(.foregroundControl)
        guard secondaryMacSubscriptions[ownerKey] === sub,
              isCurrentMacSwitchAttempt(switchAttemptID) else {
            await retireSecondaryPromotionCandidate(sub)
            return .unavailable
        }
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
                        vacatingControlOwnerKey: ownerKey
                    )
            }
            if !previousForegroundCanStayWarm,
               isFocusedConnectionCurrent(previousForegroundConnection) {
                // Close request admission on the main actor before teardown
                // yields. `remoteClient` still points at this client until the
                // promoted owner is adopted, so it must not reopen while the
                // old transport is closing.
                previousForegroundConnection.client.retire()
                await previousForegroundConnection.client.disconnect()
            }
        }
        guard secondaryMacSubscriptions[ownerKey] === sub,
              isCurrentMacSwitchAttempt(switchAttemptID) else {
            await retireSecondaryPromotionCandidate(sub)
            if let previousForegroundConnection {
                invalidateFocusedConnectionAfterAbortedHandoff(
                    previousForegroundConnection
                )
            }
            return .unavailable
        }
        let previousForegroundKey = foregroundMacKey
        let previousForegroundTag = activeMacInstanceTag
        sub.detachKeepingClient()
        let displayName = workspacesByMac[ownerKey]?.displayName
        var demotedForegroundSubscription: SecondaryMacSubscription?
        var demotedForegroundNeedsActivation = false
        // Compare OWNER KEYS, not device ids: promoting a sibling build of the
        // foreground's own physical Mac still changes owners, and skipping the
        // handoff here would leave two focused registry entries.
        if previousForegroundID != nil,
           let previousForegroundConnection,
           previousForegroundConnection.ownerKey != sub.ownerKey {
            if previousForegroundCanStayWarm {
                let subscription = makeControlSubscription(
                    from: previousForegroundConnection
                )
                guard exchangePromotedControlForDemotedFocus(
                    promotedControl: sub,
                    demotedControl: subscription,
                    replacing: previousForegroundConnection
                ) else {
                    if registryOwnsClient(
                        of: previousForegroundConnection
                    ) {
                        subscription.detachKeepingClient()
                    } else {
                        subscription.cancel()
                    }
                    await retireSecondaryPromotionCandidate(sub)
                    invalidateFocusedConnectionAfterAbortedHandoff(
                        previousForegroundConnection
                    )
                    return .unavailable
                }
                focusedHandoffPreparedGenerations.remove(
                    previousForegroundConnection.generation
                )
                let retainedSubscription = secondaryMacSubscriptions[
                    previousForegroundConnection.ownerKey
                ] ?? subscription
                demotedForegroundSubscription = retainedSubscription
                demotedForegroundNeedsActivation =
                    retainedSubscription === subscription
                // The old foreground's feed lived under its bare device key;
                // as a TAGGED secondary its refreshes publish under the
                // pairing key, so the bare source would linger as a duplicate
                // that can never resolve its client again.
                if let previousForegroundID,
                   subscription.ownerKey.pairingID != previousForegroundID {
                    removeNotificationFeedSnapshot(
                        macDeviceID: previousForegroundID
                    )
                }
            } else {
                removeControlCapability(
                    ifMatching: previousForegroundConnection
                )
                removeFocusedConnection(ifMatching: previousForegroundConnection)
            }
        }
        guard (demotedForegroundSubscription != nil
                  || secondaryMacSubscriptions[ownerKey] === sub),
              isCurrentMacSwitchAttempt(switchAttemptID) else {
            await retireSecondaryPromotionCandidate(sub)
            return .unavailable
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
        // The foreground refetches this feed under the bare device key; the
        // pairing-keyed source would otherwise linger as stale offline rows,
        // and a sibling switch must not reuse the old build's device-keyed
        // revision floor.
        removeNotificationFeedSnapshot(macDeviceID: ownerKey.pairingID)
        resetForegroundNotificationFeedIfInstanceChanged(
            previousDeviceID: previousForegroundID,
            previousTag: previousForegroundTag,
            newDeviceID: macID,
            newTag: activeMacInstanceTag
        )
        connectedHostName = placeholderHostName(for: sub.ticket, firstRoute: sub.route)
        foregroundMacDeviceID = macID
        // The control entry's aggregate state was keyed by the STORED tag.
        // The foreground key uses the live (authenticated-adopted) tag, so
        // move the snapshot when adoption changed the key; otherwise the same
        // Mac would appear twice until the next full aggregation pass.
        if ownerKey != foregroundMacKey,
           let promotedState = workspacesByMac[ownerKey] {
            workspacesByMac[ownerKey] = nil
            workspacesByMac[foregroundMacKey] = promotedState
        }
        supportedHostCapabilities = sub.supportedHostCapabilities
        // Promotion has already authenticated this capability snapshot on the
        // control connection. Publish its terminal mode synchronously so input
        // can use the warm connection immediately while the render listener
        // attaches and refreshes status.
        terminalOutputTransport = Self.resolvedTerminalOutputTransport(
            capabilities: sub.supportedHostCapabilities,
            terminalFidelity: nil
        )
        let promotedConnection = MacConnection(
            macDeviceID: macID,
            ticket: sub.ticket,
            route: sub.route,
            client: sub.client,
            generation: liveConnectionGeneration,
            displayName: displayName ?? connectedHostName,
            storedInstanceTag: sub.storedInstanceTag,
            authenticatedInstanceTag: sub.authenticatedInstanceTag,
            supportedHostCapabilities: sub.supportedHostCapabilities,
            actionCapabilities: sub.actionCapabilities
        )
        installFocusedConnection(promotedConnection)
        if let previousForegroundConnection,
           let demotedForegroundSubscription {
            if demotedForegroundNeedsActivation {
                startFocusTransitionMaintenance(
                    for: previousForegroundConnection.client
                ) { [weak self] in
                    await self?.activateDemotedControlConnection(
                        demotedForegroundSubscription,
                        from: previousForegroundConnection
                    )
                }
            } else {
                let demoted = demotedForegroundSubscription
                startFocusTransitionMaintenance(
                    for: previousForegroundConnection.client
                ) { [weak self] in
                    guard let self else { return }
                    await self.synchronizeTransportSessionPurpose(
                        previousForegroundConnection.client
                    )
                    // The reuse branch skips activation catch-up; reseed the
                    // demoted peer's pairing-keyed notification feed.
                    self.scheduleSecondaryNotificationFeedRefresh(
                        macDeviceID: demoted.ownerKey.pairingID,
                        client: demoted.client,
                        displayName: demoted.displayName
                    )
                }
            }
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
            await retirePromotedConnectionForFreshDial(
                promotedConnection,
                subscription: sub,
                switchAttemptID: switchAttemptID
            )
            return .unavailable
        }
        guard foregroundEventsReady else {
            stopTerminalRefreshPolling()
            await retirePromotedConnectionForFreshDial(
                promotedConnection,
                subscription: sub,
                switchAttemptID: switchAttemptID
            )
            return .unavailable
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
            await retirePromotedConnectionForFreshDial(
                promotedConnection,
                subscription: sub,
                switchAttemptID: switchAttemptID
            )
            return .unavailable
        }
        guard case let .received(authoritativeSnapshot) =
                authoritativeWorkspaceAttempt else {
            stopTerminalRefreshPolling()
            await retirePromotedConnectionForFreshDial(
                promotedConnection,
                subscription: sub,
                switchAttemptID: switchAttemptID
            )
            return .unavailable
        }
        let eventRaced =
            workspaceListEventGeneration != snapshotEventGeneration
        let newerWorkspaceStateApplied =
            foregroundWorkspaceStateRevision != snapshotStateRevision
        if eventRaced, !newerWorkspaceStateApplied {
            // The event fetch is part of the promotion's freshness contract.
            // If it fails, fail closed and let the normal switch path redial
            // instead of returning success with the older control snapshot.
            for _ in 0 ..< 3
                where foregroundWorkspaceStateRevision
                    == snapshotStateRevision {
                guard let racedRefresh = workspaceListRefreshTask else {
                    break
                }
                _ = await racedRefresh.value
            }
            guard foregroundWorkspaceStateRevision
                    != snapshotStateRevision,
                  isCurrentMacSwitchAttempt(switchAttemptID),
                  remoteClient === sub.client,
                  foregroundMacDeviceID == macID else {
                stopTerminalRefreshPolling()
                await retirePromotedConnectionForFreshDial(
                    promotedConnection,
                    subscription: sub,
                    switchAttemptID: switchAttemptID
                )
                return .unavailable
            }
        } else if !newerWorkspaceStateApplied {
            workspacesByMac[foregroundMacKey] = MacWorkspaceState(
                macDeviceID: macID,
                instanceTag: activeMacInstanceTag,
                displayName: displayName,
                workspaces: authoritativeSnapshot.workspaces,
                groups: authoritativeSnapshot.groups
                    ?? workspacesByMac[foregroundMacKey]?.groups
                    ?? priorSecondaryGroups,
                // Preserve cached rows for continuity, but require group
                // metadata from this promotion before trusting a destination.
                workspaceGroupsAreAuthoritative: authoritativeSnapshot.groups != nil,
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
        return .promoted
    }
}
