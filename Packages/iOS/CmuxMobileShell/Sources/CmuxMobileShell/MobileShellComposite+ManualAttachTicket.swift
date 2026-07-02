import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxMobileTransport
import Foundation

@MainActor
extension MobileShellComposite {
    func boundedPairingRequestTimeoutNanoseconds(
        runtime: any MobileSyncRuntime,
        attemptStartedAt: Date
    ) -> UInt64 {
        let requestTimeout = runtime.pairingRequestTimeoutNanoseconds
        let attemptTimeout = runtime.pairingAttemptTimeoutNanoseconds
        guard attemptTimeout > 0 else {
            return requestTimeout
        }

        let elapsedSeconds = max(0, runtime.now().timeIntervalSince(attemptStartedAt))
        let elapsedNanoseconds = UInt64((elapsedSeconds * 1_000_000_000).rounded(.up))
        guard elapsedNanoseconds < attemptTimeout else {
            return 0
        }
        return min(requestTimeout, attemptTimeout - elapsedNanoseconds)
    }

    func syntheticManualHostTicket(
        displayName: String,
        macDeviceID: String,
        route: CmxAttachRoute
    ) throws -> CmxAttachTicket {
        try CmxAttachTicket(
            workspaceID: "manual-workspace",
            terminalID: nil,
            macDeviceID: macDeviceID,
            macDisplayName: displayName,
            routes: [route],
            expiresAt: Date().addingTimeInterval(60 * 60)
        )
    }

    func manualHostTicket(
        name: String,
        host: String,
        port: Int,
        attemptStartedAt: Date?
    ) async throws -> CmxAttachTicket {
        let directRoute = try Self.manualHostRoute(host: host, port: port)
        return try await manualRouteTicket(
            displayName: name.isEmpty ? host : name,
            route: directRoute,
            syntheticMacDeviceID: "manual-\(host):\(port)",
            attemptStartedAt: attemptStartedAt
        )
    }

    /// Ticket for any stored/dialable route (host/port or iroh peer): mint via
    /// the StackAuth-authenticated flow over the route itself when policy trusts
    /// it, falling back to a synthetic ticket for hosts that lack
    /// `mobile.attach_ticket.create` — exactly the manual-host behavior,
    /// generalized so stored-Mac reconnect can dial iroh peer routes too.
    func manualRouteTicket(
        displayName: String,
        route: CmxAttachRoute,
        syntheticMacDeviceID: String,
        attemptStartedAt: Date?
    ) async throws -> CmxAttachTicket {
        if MobileShellRouteAuthPolicy.routeAllowsStackAuth(route) {
            do {
                return try await requestManualAttachTicket(
                    route: route,
                    displayName: displayName,
                    attemptStartedAt: attemptStartedAt
                )
            } catch {
                guard Self.shouldFallbackToSyntheticManualTicket(after: error) else {
                    throw error
                }
            }
        }
        return try syntheticManualHostTicket(
            displayName: displayName,
            macDeviceID: syntheticMacDeviceID,
            route: route
        )
    }

    static func shouldFallbackToSyntheticManualTicket(after error: any Error) -> Bool {
        guard case let MobileShellConnectionError.rpcError(code, message) = error else {
            return false
        }
        let normalizedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let normalizedCode,
           ["method_not_found", "not_found", "unknown_method", "unsupported_method"].contains(normalizedCode) {
            return true
        }
        return normalizedMessage.contains("unknown method")
            || normalizedMessage.contains("method not found")
            || normalizedMessage.contains("unsupported method")
            || normalizedMessage.contains("ticket unavailable")
            || normalizedMessage.contains("ticket not available")
    }

    func requestManualAttachTicket(
        route: CmxAttachRoute,
        displayName: String,
        attemptStartedAt: Date?
    ) async throws -> CmxAttachTicket {
        guard let runtime else {
            throw MobileShellConnectionError.insecureManualRoute
        }
        let probeTicket = try syntheticManualHostTicket(
            displayName: displayName,
            macDeviceID: "manual-ticket-request",
            route: route
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: probeTicket,
            allowsStackAuthFallback: true,
            connectAttemptRegistry: connectAttemptRegistry,
            stackTokenGate: stackTokenGate,
            stackTokenForceRefreshGate: stackTokenForceRefreshGate
        )
        let timeoutNanoseconds: UInt64
        if let attemptStartedAt {
            timeoutNanoseconds = boundedPairingRequestTimeoutNanoseconds(
                runtime: runtime,
                attemptStartedAt: attemptStartedAt
            )
            guard timeoutNanoseconds > 0 else {
                throw MobileShellConnectionError.requestTimedOut
            }
        } else {
            timeoutNanoseconds = runtime.pairingRequestTimeoutNanoseconds
        }
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.attach_ticket.create",
            params: [
                "ttl_seconds": 3600,
                "scope": "mac",
            ]
        )
        let resultData: Data
        do {
            resultData = try await client.sendRequest(request, timeoutNanoseconds: timeoutNanoseconds)
        } catch {
            await client.disconnect()
            throw error
        }
        await client.disconnect()
        let response = try MobileManualAttachTicketCreateResponse.decode(resultData)
        return try response.ticket.constrainingRoutes(to: [route], fallbackDisplayName: displayName)
    }
}
