import CMUXMobileCore
import CmuxMobileShellModel

enum PendingManualHostTrust {
    case manual(
        name: String,
        host: String,
        port: Int,
        pairedMacDeviceID: String?,
        recordsPairingAttempt: Bool,
        ifStillCurrent: (() -> Bool)?
    )
    case pairingURL(rawURL: String, acceptedVersionWarning: Bool)
}

enum ManualHostTrustApprovalQueued: Error {
    case required
}

@MainActor
extension MobileShellComposite {
    func clearManualHostTrustWarning() {
        manualHostTrustWarning = nil
        pendingManualHostTrust = nil
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
        clearManualHostTrustWarning()
        await manualHostTrustStore.trust(warning.scope)
        switch pending {
        case let .manual(name, host, port, pairedMacDeviceID, recordsPairingAttempt, ifStillCurrent):
            await connectManualHost(
                name: name,
                host: host,
                port: port,
                pairedMacDeviceID: pairedMacDeviceID,
                recordsPairingAttempt: recordsPairingAttempt,
                ifStillCurrent: ifStillCurrent
            )
            return connectionState == .connected ? .connected : .failed
        case let .pairingURL(rawURL, acceptedVersionWarning):
            return await connectPairingURLResult(
                rawURL,
                acceptedVersionWarning: acceptedVersionWarning
            )
        }
    }
}
