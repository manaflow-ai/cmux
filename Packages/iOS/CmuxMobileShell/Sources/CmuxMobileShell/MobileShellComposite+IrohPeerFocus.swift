internal import CMUXMobileCore
internal import CmuxMobileRPC
import Foundation

@MainActor
extension MobileShellComposite {
    /// Re-read stored authority and hidden state for a warm-focus candidate.
    /// The fast path commits synchronously on cached values, so ownership
    /// revoked or a Mac hidden after admission must be caught here; a false
    /// return routes the switch to the validated legacy promotion instead.
    /// `focusWarmIrohPeer` re-checks switch ownership and subscription
    /// identity synchronously after this await, so nothing can interleave
    /// between validation and the commit that the commit does not re-verify.
    func warmIrohFocusCandidateIsAuthorized(
        _ ownerKey: MacPairingKey
    ) async -> Bool {
        guard let subscription = secondaryMacSubscriptions[ownerKey],
              subscription.route.kind == .iroh,
              subscription.client !== remoteClient else {
            return false
        }
        guard let scope = await currentScopeSnapshot() else { return false }
        guard case .authorized = await readSecondaryStoredAuthority(
            macDeviceID: subscription.macDeviceID,
            storedInstanceTag: subscription.storedInstanceTag,
            scope: scope
        ) else { return false }
        return await !isHiddenMacDeviceID(
            subscription.macDeviceID,
            instanceTag: subscription.storedInstanceTag,
            scope: scope
        )
    }

    /// Move focus to an already admitted Iroh peer without changing either
    /// peer's control subscription or waiting for terminal teardown RPCs.
    func focusWarmIrohPeer(
        _ ownerKey: MacPairingKey,
        switchAttemptID: UUID
    ) -> Bool {
        guard isCurrentMacSwitchAttempt(switchAttemptID),
              let subscription = secondaryMacSubscriptions[ownerKey],
              subscription.route.kind == .iroh,
              subscription.client !== remoteClient,
              !subscription.isTransitioningToFocus,
              workspacesByMac[ownerKey]?.status == .connected else {
            return false
        }

        let macDeviceID = subscription.macDeviceID
        let promotedInstanceTag = subscription.authenticatedInstanceTag
            ?? subscription.storedInstanceTag
        guard ownerKey == MacPairingKey(
            macDeviceID: macDeviceID,
            instanceTag: promotedInstanceTag
        ) else {
            // An adopted tag changes aggregate ownership. The legacy promotion
            // path performs the required authority re-key and snapshot repair.
            return false
        }

        let previousForegroundKey = foregroundMacKey
        let previousForegroundID = foregroundMacDeviceID
        let previousForegroundTag = activeMacInstanceTag
        let previousConnection = previousForegroundID.flatMap { _ in
            connections[previousForegroundKey]
        }
        guard previousConnection?.ownerKey == previousForegroundKey
                || previousConnection == nil else {
            return false
        }
        let previousAnonymousClient = previousConnection == nil
            ? remoteClient
            : nil
        let pendingTerminalHandoff = remoteClient.flatMap {
            beginTerminalSubscriptionHandoff(on: $0)
        }

        var demotedSubscription: SecondaryMacSubscription?
        var installedDemotedControl = false
        if let previousConnection,
           previousConnection.client !== subscription.client {
            if let existing = secondaryMacSubscriptions[
                previousConnection.ownerKey
            ], existing.client === previousConnection.client {
                demotedSubscription = existing
            } else {
                let control = makeControlSubscription(
                    from: previousConnection
                )
                guard installControlAlongsideFocus(
                    control,
                    replacing: previousConnection
                ) else {
                    restoreTerminalSubscriptionAfterAbortedFastFocus(
                        pendingTerminalHandoff
                    )
                    return false
                }
                demotedSubscription = control
                installedDemotedControl = true
            }
        }

        let generation = UUID()
        let displayName = workspacesByMac[ownerKey]?.displayName
            ?? subscription.displayName
        let promotedConnection = MacConnection(
            macDeviceID: macDeviceID,
            ticket: subscription.ticket,
            route: subscription.route,
            client: subscription.client,
            generation: generation,
            displayName: displayName,
            storedInstanceTag: subscription.storedInstanceTag,
            authenticatedInstanceTag:
                subscription.authenticatedInstanceTag,
            supportedHostCapabilities:
                subscription.supportedHostCapabilities,
            actionCapabilities: subscription.actionCapabilities
        )
        guard installFocusedConnectionPreservingControl(
            promotedConnection
        ) else {
            if installedDemotedControl, let demotedSubscription {
                secondaryMacSubscriptions[demotedSubscription.ownerKey] = nil
            }
            restoreTerminalSubscriptionAfterAbortedFastFocus(
                pendingTerminalHandoff
            )
            return false
        }

        connectionAttemptGeneration = generation
        _ = adoptPooledRemoteClient(
            subscription.client,
            generation: generation,
            preservingTerminalHandoffFences: true
        )
        activeTicket = subscription.ticket
        activeMacInstanceTag = promotedInstanceTag
        connectedHostName = displayName
            ?? placeholderHostName(
                for: subscription.ticket,
                firstRoute: subscription.route
            )
        foregroundMacDeviceID = macDeviceID
        supportedHostCapabilities = subscription.supportedHostCapabilities
        adoptSecondaryCaffeineStatusForPromotedForeground(ownerKey: ownerKey)
        terminalOutputTransport = Self.resolvedTerminalOutputTransport(
            capabilities: subscription.supportedHostCapabilities,
            terminalFidelity: nil
        )
        removeNotificationFeedSnapshot(macDeviceID: ownerKey.pairingID)
        resetForegroundNotificationFeedIfInstanceChanged(
            previousDeviceID: previousForegroundID,
            previousTag: previousForegroundTag,
            newDeviceID: macDeviceID,
            newTag: activeMacInstanceTag
        )
        refreshMacUpdateHint(
            capabilities: subscription.supportedHostCapabilities,
            statusMacAppVersion: nil,
            macDeviceID: macDeviceID
        )
        selectWorkspaceOnCurrentForegroundMac()
        syncSelectedTerminalForWorkspace()
        activeRoute = subscription.route
        connectionState = .connected
        markMacConnectionHealthy()

        if let previousConnection, let demotedSubscription {
            if let previousForegroundID,
               demotedSubscription.ownerKey.pairingID
                != previousForegroundID {
                removeNotificationFeedSnapshot(
                    macDeviceID: previousForegroundID
                )
            }
            if installedDemotedControl {
                startFocusTransitionMaintenance(
                    for: previousConnection.client
                ) { [weak self] in
                    await self?.activateDemotedControlConnection(
                        demotedSubscription,
                        from: previousConnection
                    )
                }
            } else {
                startFocusTransitionMaintenance(
                    for: previousConnection.client
                ) { [weak self] in
                    guard let self else { return }
                    await self.synchronizeTransportSessionPurpose(
                        previousConnection.client
                    )
                    // The reuse branch skips activation catch-up; reseed the
                    // demoted peer's pairing-keyed notification feed.
                    self.scheduleSecondaryNotificationFeedRefresh(
                        macDeviceID: demotedSubscription.ownerKey.pairingID,
                        client: demotedSubscription.client,
                        displayName: demotedSubscription.displayName
                    )
                }
            }
        } else if let previousAnonymousClient,
                  previousAnonymousClient !== subscription.client {
            previousAnonymousClient.retire()
            Task { await previousAnonymousClient.disconnect() }
        }

        startFocusTransitionMaintenance(for: subscription.client) { [weak self] in
            await self?.synchronizeTransportSessionPurpose(
                subscription.client
            )
        }
        let readiness = MobileTerminalEventSubscriptionReadiness()
        startTerminalRefreshPolling(subscriptionReadiness: readiness)
        if let pendingTerminalHandoff {
            cleanUpRetiredTerminalSubscription(
                pendingTerminalHandoff,
                after: readiness
            )
        }

        dropStalePreviousForeground(previousForegroundKey)
        scheduleForegroundNotificationFeedRefresh(
            client: subscription.client
        )
        scheduleSecondaryAggregation()
        Task { @MainActor [weak self] in
            guard let self,
                  let scope = await self.currentScopeSnapshot(),
                  self.isCurrentMacSwitchAttempt(switchAttemptID)
                    || self.foregroundMacKey == ownerKey else {
                return
            }
            self.enqueueActivePairedMacWrite(
                macDeviceID: macDeviceID,
                instanceTag: subscription.storedInstanceTag,
                scope: scope,
                reloadAfterWrite: false
            )
        }
        return true
    }

    /// Restore the existing listener if a synchronous registry precondition
    /// rejects the fast handoff before focus changes.
    private func restoreTerminalSubscriptionAfterAbortedFastFocus(
        _ pending: PendingTerminalSubscriptionHandoff?
    ) {
        guard let pending else { return }
        Task { @MainActor [weak self] in
            await self?.drainTerminalSubscriptionHandoff(pending)
            guard let self else { return }
            // Release the fence unconditionally; only the restart is gated on
            // this client still being focused. A fence left behind after focus
            // moved on would block a later owner of the same object identity.
            self.finishTerminalSubscriptionHandoff(pending)
            guard self.remoteClient === pending.client else { return }
            self.startTerminalRefreshPolling()
        }
    }

    /// Apply the transport's current role and retry if focus moved while the
    /// session actor accepted that update. Rapid reversals therefore converge
    /// on the latest owner instead of letting a stale task win. A newer focus
    /// transition replaces this per-client maintenance task, so a fixed retry
    /// budget prevents pathological churn from retaining the old task.
    func synchronizeTransportSessionPurpose(
        _ client: MobileCoreRPCClient
    ) async {
        for _ in 0 ..< 3 {
            guard !Task.isCancelled else { return }
            let isForeground = remoteClient === client
            await client.updateTransportSessionPurpose(
                isForeground ? .foregroundControl : .backgroundControl
            )
            guard !Task.isCancelled else { return }
            guard (remoteClient === client) != isForeground else { return }
        }
    }

    /// Drain and remove the prior peer's terminal registration only after the
    /// replacement listener has resolved. Rapid focus reversal leaves the now
    /// current client's registration intact.
    func cleanUpRetiredTerminalSubscription(
        _ pending: PendingTerminalSubscriptionHandoff,
        after readiness: MobileTerminalEventSubscriptionReadiness
    ) {
        Task { @MainActor [weak self] in
            _ = await readiness.wait()
            guard let self else { return }
            await self.drainTerminalSubscriptionHandoff(pending)
            // The old peer stays demoted whether or not the replacement
            // subscribe succeeded: failure recovery redials the CURRENT
            // foreground, never this client. Only a completed reversal (this
            // client owns focus again) keeps its registration; otherwise the
            // Mac would keep streaming terminal state to a control-only
            // session indefinitely.
            if self.remoteClient !== pending.client {
                _ = await self.unsubscribeTerminalEventStream(
                    on: pending.client
                )
            }
            self.finishTerminalSubscriptionHandoff(pending)
        }
    }
}
