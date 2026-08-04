internal import CMUXMobileCore
internal import CmuxMobileRPC
import Foundation

@MainActor
extension MobileShellComposite {
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
                Task { @MainActor [weak self] in
                    await self?.activateDemotedControlConnection(
                        demotedSubscription,
                        from: previousConnection
                    )
                }
            } else {
                Task { @MainActor [weak self] in
                    await self?.synchronizeTransportSessionPurpose(
                        previousConnection.client
                    )
                }
            }
        } else if let previousAnonymousClient,
                  previousAnonymousClient !== subscription.client {
            previousAnonymousClient.retire()
            Task { await previousAnonymousClient.disconnect() }
        }

        Task { @MainActor [weak self] in
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
                    || self.foregroundMacDeviceID == macDeviceID else {
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
            guard let self, self.remoteClient === pending.client else { return }
            self.finishTerminalSubscriptionHandoff(pending)
            self.startTerminalRefreshPolling()
        }
    }

    /// Apply the transport's current role and retry if focus moved while the
    /// session actor accepted that update. Rapid reversals therefore converge
    /// on the latest owner instead of letting a stale task win.
    func synchronizeTransportSessionPurpose(
        _ client: MobileCoreRPCClient
    ) async {
        while !Task.isCancelled {
            let isForeground = remoteClient === client
            await client.updateTransportSessionPurpose(
                isForeground ? .foregroundControl : .backgroundControl
            )
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
            let replacementIsReady = await readiness.wait()
            guard let self else { return }
            await self.drainTerminalSubscriptionHandoff(pending)
            if replacementIsReady,
               self.remoteClient !== pending.client {
                _ = await self.unsubscribeTerminalEventStream(
                    on: pending.client
                )
            }
            self.finishTerminalSubscriptionHandoff(pending)
        }
    }
}
