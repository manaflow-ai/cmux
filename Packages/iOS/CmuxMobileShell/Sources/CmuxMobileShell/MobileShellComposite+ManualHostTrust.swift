import CMUXMobileCore
import CmuxMobileRPC
public import CmuxMobileShellModel
import Foundation

private struct ManualHostReapproval {
    let name: String
    let host: String
    let port: Int
    let route: CmxAttachRoute
    let pairedMacDeviceID: String?
    let instanceTagExpectation: MobileMacInstanceTagExpectation
}

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
        guard let approvalAttemptID = pendingManualHostTrust?.attemptID else {
            clearManualHostTrustWarning()
            return .superseded
        }
        if let resetTask = manualHostTrustResetTask {
            await resetTask.value
        }
        guard let warning = manualHostTrustWarning,
              let pending = pendingManualHostTrust,
              pending.attemptID == approvalAttemptID else {
            if pendingManualHostTrust?.attemptID == approvalAttemptID {
                clearManualHostTrustWarning()
            }
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
        case let .manual(
            _, name, host, port, route, pairedMacDeviceID, instanceTagExpectation,
            recordsPairingAttempt, macSwitchAttemptID, ifStillCurrent
        ):
            let result = await connectManualHost(
                name: name,
                host: host,
                port: port,
                pairedMacDeviceID: pairedMacDeviceID,
                instanceTagExpectation: instanceTagExpectation,
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

    func cancelManualHostTrustExpiration() {
        manualHostTrustExpirationTask?.cancel()
        manualHostTrustExpirationTask = nil
        manualHostTrustExpirationOwner = nil
    }

    func scheduleManualHostTrustExpirationForActiveRoute() {
        guard let route = activeRoute,
              let client = remoteClient,
              connectionState == .connected,
              let scope = manualHostTrustScope(for: route) else {
            cancelManualHostTrustExpiration()
            return
        }
        let owner = ManualHostTrustExpirationOwner(
            scope: scope,
            route: route,
            client: client,
            generation: connectionGeneration,
            authScope: manualHostRPCAuthScope
        )
        guard manualHostTrustExpirationOwner != owner else { return }
        cancelManualHostTrustExpiration()
        manualHostTrustExpirationOwner = owner
        let trustStore = manualHostTrustStore
        manualHostTrustExpirationTask = Task { @MainActor [weak self] in
            guard let expiration = await trustStore.expirationDate(for: scope),
                  let self,
                  self.manualHostTrustExpirationIsCurrent(owner) else { return }
            let delay = expiration.timeIntervalSince(self.runtime?.now() ?? Date())
            if delay > 0 {
                try? await ContinuousClock().sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled,
                  self.manualHostTrustExpirationIsCurrent(owner),
                  !(await trustStore.isTrusted(scope)),
                  self.manualHostTrustExpirationIsCurrent(owner) else { return }
            self.rotateManualHostRPCAuthScope()
            _ = self.queueForegroundManualHostReapproval(route: route)
        }
    }

    private func manualHostTrustExpirationIsCurrent(_ owner: ManualHostTrustExpirationOwner) -> Bool {
        connectionState == .connected
            && manualHostTrustExpirationOwner == owner
            && remoteClient === owner.client
            && connectionGeneration == owner.generation
            && activeRoute == owner.route
            && manualHostRPCAuthScope == owner.authScope
    }

    func scheduleManualHostTrustExpirationForSecondarySubscription(
        _ subscription: SecondaryMacSubscription,
        stackUserID: String
    ) {
        subscription.trustExpirationTask?.cancel()
        subscription.trustExpirationTask = nil
        guard let scope = manualHostTrustScope(
            for: subscription.route,
            stackUserID: stackUserID
        ) else { return }
        let trustStore = manualHostTrustStore
        subscription.trustExpirationTask = Task { @MainActor [weak self, weak subscription] in
            guard let expiration = await trustStore.expirationDate(for: scope),
                  let self,
                  let subscription,
                  self.secondaryMacSubscriptions[subscription.macDeviceID] === subscription else {
                return
            }
            let delay = expiration.timeIntervalSince(self.runtime?.now() ?? Date())
            if delay > 0 {
                // Trust expiry is an intentional bounded deadline tied to this subscription's lifecycle.
                try? await ContinuousClock().sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled,
                  self.secondaryMacSubscriptions[subscription.macDeviceID] === subscription,
                  !(await trustStore.isTrusted(scope)),
                  self.secondaryMacSubscriptions[subscription.macDeviceID] === subscription else {
                return
            }
            self.invalidateSecondaryConnection(
                macDeviceID: subscription.macDeviceID,
                client: subscription.client
            )
        }
    }

    /// Revokes plaintext-route credentials at any boundary that may represent a new network.
    /// - Returns: Whether an active manual-host connection was queued for reapproval.
    @discardableResult
    func invalidateManualHostTrustForNetworkBoundary() -> Bool {
        let reapproval = reissuableManualHostApproval()
        revokeSecondaryManualHostSubscriptions()
        rotateManualHostRPCAuthScope()
        invalidatePairingAttempt()
        clearSupersededManualHostTrustWarning()

        if manualHostTrustResetTask == nil {
            manualHostTrustResetGeneration &+= 1
            let resetGeneration = manualHostTrustResetGeneration
            let trustStore = manualHostTrustStore
            manualHostTrustResetTask = Task { @MainActor [weak self] in
                await trustStore.removeAll()
                guard let self,
                      self.manualHostTrustResetGeneration == resetGeneration else { return }
                self.manualHostTrustResetTask = nil
            }
        }

        if let reapproval {
            let attemptID = beginPairingValidationAttempt()
            queueManualHostTrustWarning(
                route: reapproval.route,
                displayHost: reapproval.host,
                pending: .manual(
                    attemptID: attemptID,
                    name: reapproval.name,
                    host: reapproval.host,
                    port: reapproval.port,
                    route: reapproval.route,
                    pairedMacDeviceID: reapproval.pairedMacDeviceID,
                    instanceTagExpectation: reapproval.instanceTagExpectation,
                    recordsPairingAttempt: false,
                    macSwitchAttemptID: nil,
                    ifStillCurrent: nil
                )
            )
            return true
        }

        guard remoteClient != nil else { return false }
        return queueForegroundManualHostReapproval(route: activeRoute)
    }

    private func reissuableManualHostApproval() -> ManualHostReapproval? {
        guard manualHostTrustWarning != nil,
              case let .manual(
                  _, name, host, port, route, pairedMacDeviceID, instanceTagExpectation,
                  recordsPairingAttempt, macSwitchAttemptID, ifStillCurrent
              )? = pendingManualHostTrust,
              !recordsPairingAttempt,
              macSwitchAttemptID == nil,
              ifStillCurrent == nil else {
            return nil
        }
        return ManualHostReapproval(
            name: name,
            host: host,
            port: port,
            route: route,
            pairedMacDeviceID: pairedMacDeviceID,
            instanceTagExpectation: instanceTagExpectation
        )
    }

    private func revokeSecondaryManualHostSubscriptions() {
        let subscriptions = secondaryMacSubscriptions.values.filter {
            $0.route.kind == .manualHost
        }
        for subscription in subscriptions {
            invalidateSecondaryConnection(
                macDeviceID: subscription.macDeviceID,
                client: subscription.client
            )
        }
    }
}
