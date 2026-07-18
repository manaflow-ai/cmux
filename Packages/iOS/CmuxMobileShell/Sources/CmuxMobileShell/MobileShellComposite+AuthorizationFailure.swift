import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation

@MainActor
extension MobileShellComposite {
    func handleAuthorizationFailureIfNeeded(
        _ error: any Error,
        owner: MobileShellAuthorizationFailureOwner
    ) -> Bool {
        guard requiresAuthorizationFailureHandling(error) else {
            return false
        }
        if case let .foreground(client, generation, _) = owner,
           (remoteClient !== client || connectionGeneration != generation) {
            return true
        }
        if let connectionError = error as? MobileShellConnectionError,
           case .insecureManualRoute = connectionError {
            switch owner {
            case let .foreground(_, _, route):
                if queueForegroundManualHostReapproval(route: route) {
                    return true
                }
            case let .connectionAttempt(route, preservingActiveConnection):
                if !preservingActiveConnection,
                   queueForegroundManualHostReapproval(route: route) {
                    return true
                }
            case let .secondary(macDeviceID, client, _):
                invalidateSecondaryConnection(macDeviceID: macDeviceID, client: client)
                return true
            }
        }
        if case let .secondary(macDeviceID, client, _) = owner {
            invalidateSecondaryConnection(macDeviceID: macDeviceID, client: client)
            return true
        }
        let category = MobilePairingFailureCategory.classify(error: error, route: owner.route)
        applyAuthorizationFailure(
            category,
            preservingActiveConnection: owner.preservesActiveConnection
        )
        return true
    }

    func queueForegroundManualHostReapproval(route: CmxAttachRoute?) -> Bool {
        guard let route,
              MobileShellRouteAuthPolicy().routeRequiresManualHostTrust(route),
              case let .hostPort(host, port) = route.endpoint else {
            return false
        }
        let displayName = connectedHostName.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairedMacDeviceID = foregroundMacDeviceID ?? activeTicket?.macDeviceID
        let attemptID = beginPairingValidationAttempt()
        queueManualHostTrustWarning(
            route: route,
            displayHost: host,
            pending: .manual(
                attemptID: attemptID,
                name: displayName.isEmpty ? host : displayName,
                host: host,
                port: port,
                route: route,
                pairedMacDeviceID: pairedMacDeviceID,
                instanceTagExpectation: MobileMacInstanceTagAuthority.expectation(
                    storedInstanceTag: activeMacInstanceTag
                ),
                recordsPairingAttempt: false,
                macSwitchAttemptID: nil,
                ifStillCurrent: nil
            )
        )
        disconnectForegroundForManualHostReapproval()
        return true
    }

    func invalidateSecondaryConnection(
        macDeviceID: String,
        client: MobileCoreRPCClient
    ) {
        guard let subscription = secondaryMacSubscriptions[macDeviceID],
              subscription.client === client else {
            return
        }
        subscription.cancel()
        secondaryMacSubscriptions[macDeviceID] = nil
        removeSecondaryConnectionFromPool(macDeviceID: macDeviceID)
        if var state = workspacesByMac[macDeviceID] {
            state.status = .unavailable
            workspacesByMac[macDeviceID] = state
        }
    }

    func requiresAuthorizationFailureHandling(_ error: any Error) -> Bool {
        guard let connectionError = error as? MobileShellConnectionError else {
            return false
        }
        switch connectionError {
        case .attachTicketExpired, .authorizationFailed, .accountMismatch, .insecureManualRoute:
            return true
        case let .rpcError(code, message):
            let normalizedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let normalizedCode,
               ["unauthorized", "forbidden", "invalid_token", "token_expired", "expired_token", "auth_required"].contains(normalizedCode) {
                return true
            }
            let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalizedMessage.contains("unauthorized")
                || normalizedMessage.contains("forbidden")
                || normalizedMessage.contains("invalid token")
                || normalizedMessage.contains("expired token")
                || normalizedMessage.contains("token expired")
        case .invalidResponse, .connectionClosed, .requestTimedOut, .transportWriteTimedOut:
            return false
        }
    }
}
