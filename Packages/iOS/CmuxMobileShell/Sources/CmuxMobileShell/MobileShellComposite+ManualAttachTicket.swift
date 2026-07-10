import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import CmuxMobileSupport
import CmuxMobileTransport
import Foundation
import OSLog

private let mobileManualAttachLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

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
        attemptStartedAt: Date?,
        pinnedIrohEndpointID: String? = nil
    ) async throws -> CmxAttachTicket {
        guard routeAllowsTokenBearingDial(route, pinnedIrohEndpointID: pinnedIrohEndpointID) else {
            throw MobileShellConnectionError.insecureManualRoute
        }
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

    func connectStoredMacHost(
        name: String,
        host: String,
        port: Int,
        pairedMacDeviceID: String,
        ifStillCurrent: (() -> Bool)? = nil
    ) async {
        await connectManualHost(
            name: name,
            host: host,
            port: port,
            pairedMacDeviceID: pairedMacDeviceID,
            recordsPairingAttempt: false,
            ifStillCurrent: ifStillCurrent
        )
    }

    /// - Parameter pairedMacDeviceID: the REAL paired-Mac device id when the caller
    ///   knows it (switch/reconnect/device-row paths). A manual host whose Mac lacks
    ///   `mobile.attach_ticket.create` connects via a synthetic `manual-...` ticket;
    ///   passing the real id keys the foreground aggregate state under it instead of
    ///   the synthetic id. `nil` for a genuinely manual/unknown host.
    func connectManualHost(
        name: String,
        host: String,
        port: Int,
        pairedMacDeviceID: String? = nil,
        recordsPairingAttempt: Bool,
        ifStillCurrent: (() -> Bool)? = nil
    ) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedHost = MobileShellRouteAuthPolicy.normalizedManualHost(host) else {
            connectionError = L10n.string("mobile.addDevice.invalidHost", defaultValue: "Enter a host or IP address, without spaces or URL paths.")
            connectionErrorGuidance = nil
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
            analytics.capture("ios_pairing_failed", [
                "method": .string("manual"),
                "reason": .string("invalid_host"),
                "failure_phase": .string("validation"),
                "is_first_pair": .bool(!hasKnownPairedMac),
            ])
            return
        }
        guard (1...65535).contains(port) else {
            connectionError = L10n.string("mobile.addDevice.invalidPort", defaultValue: "Enter a port from 1 to 65535.")
            connectionErrorGuidance = nil
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
            analytics.capture("ios_pairing_failed", [
                "method": .string("manual"),
                "reason": .string("invalid_port"),
                "failure_phase": .string("validation"),
                "is_first_pair": .bool(!hasKnownPairedMac),
            ])
            return
        }

        guard let directRoute = try? Self.manualHostRoute(host: normalizedHost, port: port) else {
            // Unreachable in practice: host and port were both validated above,
            // and route construction only rejects an empty host or invalid port.
            connectionError = L10n.string("mobile.addDevice.invalidHost", defaultValue: "Enter a host or IP address, without spaces or URL paths.")
            connectionErrorGuidance = nil
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
            return
        }
        await connectManualRoute(
            displayName: trimmedName.isEmpty ? normalizedHost : trimmedName,
            route: directRoute,
            syntheticMacDeviceID: "manual-\(normalizedHost):\(port)",
            pairedMacDeviceID: pairedMacDeviceID,
            recordsPairingAttempt: recordsPairingAttempt,
            ifStillCurrent: ifStillCurrent
        )
    }

    /// The route-generic connect core shared by the manual-host flow and the
    /// stored-Mac reconnect: mint a ticket over `route` (StackAuth mint with
    /// synthetic fallback), then attach. Taking a full ``CmxAttachRoute`` is
    /// what lets the stored-Mac auto-connect dial an iroh peer route - a
    /// cmuxRelay Mac publishes no host/port route at all.
    func connectManualRoute(
        displayName: String,
        route: CmxAttachRoute,
        syntheticMacDeviceID: String,
        pairedMacDeviceID: String? = nil,
        recordsPairingAttempt: Bool,
        ifStillCurrent: (() -> Bool)? = nil,
        pinnedIrohEndpointID: String? = nil
    ) async {
        activeRoute = route
        let attemptID = recordsPairingAttempt ? beginPairingAttempt(method: "manual") : beginPairingValidationAttempt()
        // Fast offline preflight: fail immediately instead of stacking
        // per-route timeouts into the opaque ~60s blob.
        guard await failPairingIfOffline(attemptID: attemptID, phase: "preflight", routes: [route]) == .proceed else { return }
        do {
            let ticket = try await manualRouteTicket(
                displayName: displayName,
                route: route,
                syntheticMacDeviceID: syntheticMacDeviceID,
                attemptStartedAt: pairingAttemptStartedAt,
                pinnedIrohEndpointID: pinnedIrohEndpointID
            )
            guard isCurrentPairingAttempt(attemptID) else { return }
            let noThrowFailure = try await connect(
                ticket: ticket,
                allowsStackAuthFallback: true,
                pairedMacDeviceID: pairedMacDeviceID,
                ifStillCurrent: ifStillCurrent
            )
            guard isCurrentPairingAttempt(attemptID) else { return }
            if connectionState == .connected {
                recordPairingSucceeded()
            } else {
                // `connect()` returned without connecting and already set a
                // specific error; record without overwriting that message.
                recordFailureForCurrentConnectionError(phase: "connect", category: noThrowFailure)
            }
        } catch is CancellationError {
            guard isCurrentPairingAttempt(attemptID) else { return }
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
        } catch {
            guard isCurrentPairingAttempt(attemptID) else { return }
            mobileManualAttachLog.error("manual route pairing failed: \(String(describing: error), privacy: .private)")
            // A definitive auth failure (expired/invalid token after the
            // refresh-then-retry in the RPC layer already gave up) must drive the
            // re-auth prompt, not the generic "could not connect / Retry" banner.
            if disconnectForAuthorizationFailureIfNeeded(error) {
                return
            }
            let category = MobilePairingFailureCategory.classify(error: error, route: activeRoute ?? route)
            applyPairingFailure(category, phase: "connect")
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
        }
    }
}
