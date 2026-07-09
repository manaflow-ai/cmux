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

    func manualHostTrustScope(for route: CmxAttachRoute?) -> MobileManualHostTrustScope? {
        guard let route,
              MobileShellRouteAuthPolicy().routeRequiresManualHostTrust(route) else {
            return nil
        }
        return MobileManualHostTrustScope(
            route: route,
            stackUserID: identityProvider?.currentUserID
        )
    }

    func manualHostStackAuthTrusted(for route: CmxAttachRoute?) async -> Bool {
        guard let scope = manualHostTrustScope(for: route) else {
            return false
        }
        return await manualHostTrustStore.isTrusted(scope)
    }

    func manualHostStackAuthTrustProvider(
        for route: CmxAttachRoute?
    ) -> @Sendable () async -> Bool {
        guard let scope = manualHostTrustScope(for: route) else {
            return { false }
        }
        let trustStore = manualHostTrustStore
        return {
            await trustStore.isTrusted(scope)
        }
    }

    func manualHostRouteNeedsApproval(_ route: CmxAttachRoute) async -> Bool {
        guard let scope = manualHostTrustScope(for: route) else {
            return false
        }
        return !(await manualHostTrustStore.isTrusted(scope))
    }

    func firstManualHostRouteNeedingApproval(
        in routes: [CmxAttachRoute]
    ) async -> (route: CmxAttachRoute, scope: MobileManualHostTrustScope)? {
        let routeAuthPolicy = MobileShellRouteAuthPolicy()
        for route in routes {
            if let scope = manualHostTrustScope(for: route) {
                if !(await manualHostTrustStore.isTrusted(scope)) {
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
    /// - Returns: The resumed pairing attempt's connection result, or `.failed` if no warning is pending.
    @discardableResult
    public func acceptManualHostTrustWarning() async -> MobilePairingURLConnectionResult {
        guard let warning = manualHostTrustWarning,
              let pending = pendingManualHostTrust else {
            clearManualHostTrustWarning()
            return .failed
        }
        guard isPendingManualHostTrustCurrent(pending) else {
            finishPendingManualHostSwitchAttempt(pending)
            clearManualHostTrustWarning()
            return .superseded
        }
        let workspaceOpenIntent = takePendingWorkspaceOpenIntent(for: pending)
        clearManualHostTrustWarning()
        await manualHostTrustStore.trust(warning.scope)
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
}
