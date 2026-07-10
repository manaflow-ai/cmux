import CMUXMobileCore
public import CmuxMobileShellModel

@MainActor
extension MobileShellComposite {
    func clearManualHostTrustWarning() {
        cancelPendingWorkspaceOpenIntent()
        manualHostTrustWarning = nil
        pendingManualHostTrust = nil
    }

    func clearSupersededManualHostTrustWarning() {
        let pending = pendingManualHostTrust
        clearManualHostTrustWarning()
        if let pending {
            finishPendingManualHostSwitchAttempt(pending)
        }
    }

    func manualHostTrustScope(
        for route: CmxAttachRoute?,
        stackUserID: String? = nil
    ) -> MobileManualHostTrustScope? {
        guard let route,
              MobileShellRouteAuthPolicy().routeRequiresManualHostTrust(route) else {
            return nil
        }
        return MobileManualHostTrustScope(
            route: route,
            stackUserID: stackUserID ?? identityProvider?.currentUserID
        )
    }

    func manualHostStackAuthTrusted(
        for route: CmxAttachRoute?,
        stackUserID: String? = nil
    ) async -> Bool {
        guard let scope = manualHostTrustScope(for: route, stackUserID: stackUserID) else {
            return false
        }
        return await manualHostTrustIsAvailable(scope)
    }

    func manualHostStackAuthTrustProvider(
        for route: CmxAttachRoute?,
        stackUserID: String? = nil
    ) -> @Sendable () async -> Bool {
        guard let scope = manualHostTrustScope(for: route, stackUserID: stackUserID) else {
            return { false }
        }
        return { [weak self] in
            guard let self else { return false }
            return await self.manualHostTrustIsAvailable(scope)
        }
    }

    func manualHostRouteNeedsApproval(
        _ route: CmxAttachRoute,
        stackUserID: String? = nil
    ) async -> Bool {
        guard let scope = manualHostTrustScope(for: route, stackUserID: stackUserID) else {
            return false
        }
        return !(await manualHostTrustIsAvailable(scope))
    }

    func firstManualHostRouteNeedingApproval(
        in routes: [CmxAttachRoute],
        stackUserID: String?
    ) async -> (route: CmxAttachRoute, scope: MobileManualHostTrustScope)? {
        let routeAuthPolicy = MobileShellRouteAuthPolicy()
        for route in routes {
            if let scope = manualHostTrustScope(for: route, stackUserID: stackUserID) {
                if !(await manualHostTrustIsAvailable(scope)) {
                    return (route, scope)
                }
                return nil
            }
            if routeAuthPolicy.routeAllowsStackAuth(route) {
                // A safer route will be selected before any later manual-host fallback.
                // Do not train the user to approve plaintext LAN unless it is needed.
                return nil
            }
        }
        return nil
    }

    func queueManualHostTrustWarning(
        route: CmxAttachRoute,
        displayHost: String,
        pending: PendingManualHostTrust
    ) {
        guard let scope = manualHostTrustScope(for: route) else {
            return
        }
        clearPairingError()
        clearPairingVersionWarning()
        if let currentPending = pendingManualHostTrust,
           currentPending.attemptID != pending.attemptID {
            cancelPendingWorkspaceOpenIntent()
            finishPendingManualHostSwitchAttempt(currentPending)
        }
        pendingManualHostTrust = pending
        manualHostTrustWarning = MobileManualHostTrustWarning(
            scope: scope,
            displayHost: displayHost
        )
    }

    /// Persists the queued manual-host trust approval and resumes the pending pairing attempt.
    /// - Returns: The resumed result, or `.superseded` when the warning is no longer current.
    @discardableResult
    public func acceptManualHostTrustWarning() async -> MobilePairingURLConnectionResult {
        if let resetTask = manualHostTrustResetTask {
            await resetTask.value
        }
        guard let warning = manualHostTrustWarning,
              let pending = pendingManualHostTrust else {
            clearManualHostTrustWarning()
            return .superseded
        }
        guard isPendingManualHostTrustCurrent(pending) else {
            finishPendingManualHostSwitchAttempt(pending)
            clearManualHostTrustWarning()
            return .superseded
        }
        let workspaceOpenIntent = takePendingWorkspaceOpenIntent(for: pending)
        let approvalAuthScope = manualHostRPCAuthScope
        clearManualHostTrustWarning()
        await manualHostTrustStore.trust(warning.scope)
        guard approvalAuthScope == manualHostRPCAuthScope else {
            // A path change can race persistence. Remove again after the write so
            // trust from the previous network epoch cannot survive the boundary.
            await manualHostTrustStore.removeAll()
            if let workspaceOpenIntent {
                cancelWorkspaceOpen(workspaceOpenIntent)
            }
            finishPendingManualHostSwitchAttempt(pending)
            return .superseded
        }
        guard isPendingManualHostTrustCurrent(pending) else {
            if let workspaceOpenIntent {
                cancelWorkspaceOpen(workspaceOpenIntent)
            }
            finishPendingManualHostSwitchAttempt(pending)
            return .superseded
        }
        switch pending {
        case let .manual(_, name, host, port, route, pairedMacDeviceID, recordsPairingAttempt, macSwitchAttemptID, ifStillCurrent):
            let result = await connectManualHost(
                name: name,
                host: host,
                port: port,
                pairedMacDeviceID: pairedMacDeviceID,
                recordsPairingAttempt: recordsPairingAttempt,
                route: route,
                pendingMacSwitchAttemptID: macSwitchAttemptID,
                ifStillCurrent: ifStillCurrent
            )
            if result == .needsUserApproval {
                pendingWorkspaceOpenIntent = workspaceOpenIntent
                return result
            }
            finishPendingManualHostSwitchAttempt(pending)
            if result == .connected, let workspaceOpenIntent {
                await resumePendingWorkspaceOpen(workspaceOpenIntent)
            } else if let workspaceOpenIntent {
                cancelWorkspaceOpen(workspaceOpenIntent)
            }
            return result
        case let .pairingURL(_, rawURL, acceptedVersionWarning, approvedRouteID):
            return await connectPairingURLResult(
                rawURL,
                acceptedVersionWarning: acceptedVersionWarning,
                approvedManualRouteID: approvedRouteID
            )
        }
    }

    private func isPendingManualHostTrustCurrent(_ pending: PendingManualHostTrust) -> Bool {
        guard !Task.isCancelled,
              isCurrentPairingAttempt(pending.attemptID),
              pending.ifStillCurrent?() != false else {
            return false
        }
        return true
    }

    private func finishPendingManualHostSwitchAttempt(_ pending: PendingManualHostTrust) {
        guard let attemptID = pending.macSwitchAttemptID else { return }
        finishMacSwitchAttempt(attemptID)
    }

    private func manualHostTrustIsAvailable(_ scope: MobileManualHostTrustScope) async -> Bool {
        guard manualHostTrustResetTask == nil else { return false }
        return await manualHostTrustStore.isTrusted(scope)
    }

    /// Revokes plaintext-route credentials at any boundary that may represent a new network.
    /// - Returns: Whether an active manual-host connection was queued for reapproval.
    @discardableResult
    func invalidateManualHostTrustForNetworkBoundary() -> Bool {
        rotateManualHostRPCAuthScope()
        invalidatePairingAttempt()
        clearSupersededManualHostTrustWarning()

        manualHostTrustResetGeneration &+= 1
        let resetGeneration = manualHostTrustResetGeneration
        manualHostTrustResetTask?.cancel()
        let trustStore = manualHostTrustStore
        manualHostTrustResetTask = Task { @MainActor [weak self] in
            await trustStore.removeAll()
            guard let self,
                  self.manualHostTrustResetGeneration == resetGeneration else { return }
            self.manualHostTrustResetTask = nil
        }

        guard remoteClient != nil else { return false }
        return queueForegroundManualHostReapproval(route: activeRoute)
    }
}
