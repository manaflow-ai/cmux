public import CMUXMobileCore
internal import CmuxMobileDiagnostics
public import CmuxMobilePairedMac
public import CmuxMobileRPC
public import CmuxMobileShellModel
internal import CmuxMobileSupport
public import CmuxMobileTransport
public import Foundation
import Observation
internal import OSLog


// MARK: - Pairing and attach tickets
extension MobileShellComposite {
    @discardableResult
    public func connectPairingURL(_ rawValue: String? = nil) async -> Bool {
        await connectPairingURLResult(rawValue).didConnect
    }

    @discardableResult
    public func connectPairingURLResult(_ rawValue: String? = nil) async -> MobilePairingURLConnectionResult {
        let rawURL = Self.normalizedPairingURL(rawValue ?? pairingCode)
        let attemptID = beginPairingAttempt(method: "qr")
        let ticket: CmxAttachTicket
        do {
            ticket = try CmxAttachTicketInput.decode(rawURL)
        } catch {
            guard isCurrentPairingAttempt(attemptID) else { return .superseded }
            connectionError = L10n.string("mobile.pairing.invalidCode", defaultValue: "Invalid pairing code.")
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
            recordPairingFailed(reason: "invalid_code", phase: "validation")
            return .failed
        }

        do {
            guard isCurrentPairingAttempt(attemptID) else { return .superseded }
            try await connect(ticket: ticket)
            guard isCurrentPairingAttempt(attemptID) else { return .superseded }
            if connectionState == .connected && activeTicket != nil {
                recordPairingSucceeded()
                return .connected
            }
            recordPairingFailed(reason: "other", phase: "connect")
            return .failed
        } catch is CancellationError {
            guard isCurrentPairingAttempt(attemptID) else { return .superseded }
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
            return .failed
        } catch {
            guard isCurrentPairingAttempt(attemptID) else { return .superseded }
            mobileShellLog.error("pairing failed: \(String(describing: error), privacy: .private)")
            // Surface a definitive auth failure as a re-auth prompt rather than a
            // generic connection error (matches the manual-host path).
            if disconnectForAuthorizationFailureIfNeeded(error) {
                recordPairingFailed(reason: "account_mismatch", phase: "auth")
                return .failed
            }
            recordPairingFailed(reason: Self.pairingFailureReason(for: error), phase: "connect")
            connectionError = Self.localizedConnectionError(for: error, route: activeRoute)
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
            return .failed
        }
    }

    public func cancelPairing() {
        pairingAttemptID = UUID()
        connectionError = nil
        connectionState = .disconnected
        macConnectionStatus = .unavailable
        clearRemoteConnectionContext()
    }

    /// Tear down the live connection and reset connection UI state, without
    /// touching the paired-Mac store or the restoring-gate hint. The switcher's
    /// ``forgetMac(macDeviceID:)`` and ``switchToMac(macDeviceID:)`` reuse this,
    /// so it must not clear ``hasKnownPairedMac`` (that belongs to the explicit
    /// forget-active path below).
    func disconnectLiveConnection() {
        suppressNextConnectionOutageEdge = true
        pairingAttemptID = UUID()
        connectionError = nil
        connectionRequiresReauth = false
        connectionState = .disconnected
        macConnectionStatus = .unavailable
        clearRemoteConnectionContext()
    }

    /// Disconnect from the currently paired Mac and forget it so the next
    /// session starts from a fresh QR scan. Clears in-memory state and the
    /// persisted active flag (other macs in SQLite stay, but none are marked
    /// active so reconnect-on-launch is a no-op until the user pairs again).
    /// Backs the "Rescan QR" action.
    public func disconnectAndForgetActiveMac() {
        let staleMacID = activeTicket?.macDeviceID
        disconnectLiveConnection()
        // Forgetting the active Mac clears the restoring hint so the next launch
        // (and the current disconnected view) shows add-device immediately. Bump
        // the reconnect generation first so an in-flight reconnect can't re-set the
        // hint or the gate flags after the user forgot the Mac.
        storedMacReconnectGeneration &+= 1
        hasKnownPairedMac = false
        isReconnectingStoredMac = false
        didFinishStoredMacReconnectAttempt = false
        if let pairedMacStore, let macID = staleMacID {
            // Fire-and-forget: forgetting the persisted mac is cleanup that must
            // not block the synchronous disconnect UI state update above.
            Task {
                do {
                    try await pairedMacStore.remove(macDeviceID: macID)
                } catch {
                    mobileShellLog.error("forgetActiveMac removal failed: \(String(describing: error), privacy: .private)")
                }
            }
        }
    }

    private static func normalizedPairingURL(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("cmux-ios://") else {
            return trimmed
        }
        let scalars = trimmed.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    func manualHostTicket(name: String, host: String, port: Int) async throws -> CmxAttachTicket {
        let directRoute = try Self.manualHostRoute(host: host, port: port)
        let displayName = name.isEmpty ? host : name
        if MobileShellRouteAuthPolicy.routeAllowsStackAuth(directRoute) {
            do {
                let ticket = try await requestManualAttachTicket(
                    route: directRoute,
                    displayName: displayName
                )
                return ticket
            } catch {
                guard Self.shouldFallbackToSyntheticManualTicket(after: error) else {
                    throw error
                }
            }
            return try Self.manualHostTicket(
                displayName: displayName,
                macDeviceID: "manual-\(host):\(port)",
                route: directRoute
            )
        }
        return try Self.manualHostTicket(
            displayName: displayName,
            macDeviceID: "manual-\(host):\(port)",
            route: directRoute
        )
    }

    private static func shouldFallbackToSyntheticManualTicket(after error: any Error) -> Bool {
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

    static func manualHostTicket(
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

    private func requestManualAttachTicket(
        route: CmxAttachRoute,
        displayName: String
    ) async throws -> CmxAttachTicket {
        guard let runtime else {
            throw MobileShellConnectionError.insecureManualRoute
        }
        let probeTicket = try Self.manualHostTicket(
            displayName: displayName,
            macDeviceID: "manual-ticket-request",
            route: route
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: probeTicket,
            allowsStackAuthFallback: true
        )
        let resultData = try await client.sendRequest(
            MobileCoreRPCClient.requestData(
                method: "mobile.attach_ticket.create",
                params: [
                    "ttl_seconds": 3600,
                    "scope": "mac",
                ]
            ),
            timeoutNanoseconds: runtime.pairingRequestTimeoutNanoseconds
        )
        let response = try MobileManualAttachTicketCreateResponse.decode(resultData)
        return try response.ticket.constrainingRoutes(to: [route], fallbackDisplayName: displayName)
    }

    /// The one shared entry every pairing flow funnels through, so it is also the
    /// single `ios_pairing_started` fire-site. `method` is `qr`/`manual`/
    /// `attach_url`; pass `nil` for non-instrumented internal flows (preview).
    func beginPairingAttempt(method: String? = nil) -> UUID {
        let attemptID = UUID()
        pairingAttemptID = attemptID
        connectionGeneration = UUID()
        cancelRemoteOperationTasks()
        rawTerminalInputBuffer.clear()
        connectionError = nil
        if let method {
            pairingAttemptStartedAt = runtime?.now() ?? Date()
            pairingAttemptMethod = method
            // Snapshot at attempt start: a successful connect mutates
            // `hasKnownPairedMac` before `succeeded` is recorded.
            pairingAttemptIsFirstPair = !hasKnownPairedMac
            analytics.capture("ios_pairing_started", [
                "method": .string(method),
                "is_first_pair": .bool(pairingAttemptIsFirstPair),
                "attempt_id": .string(attemptID.uuidString),
            ])
        } else {
            pairingAttemptStartedAt = nil
            pairingAttemptMethod = nil
        }
        return attemptID
    }

    /// Emits `ios_pairing_succeeded` once for the in-flight attempt, then clears
    /// the attempt timing so a later state change can't double-fire.
    func recordPairingSucceeded() {
        guard let method = pairingAttemptMethod else { return }
        var props: [String: AnalyticsValue] = [
            "method": .string(method),
            "is_first_pair": .bool(pairingAttemptIsFirstPair),
            "attempt_id": .string(pairingAttemptID.uuidString),
        ]
        if let startedAt = pairingAttemptStartedAt {
            let ms = Int(((runtime?.now() ?? Date()).timeIntervalSince(startedAt)) * 1000)
            props["duration_ms"] = .int(max(0, ms))
        }
        if let route = activeRoute?.kind.rawValue {
            props["route"] = .string(route)
        }
        analytics.capture("ios_pairing_succeeded", props)
        pairingAttemptStartedAt = nil
        pairingAttemptMethod = nil
    }

    /// Emits `ios_pairing_failed` once for the in-flight attempt with a reason +
    /// phase, then clears the attempt timing so it can't double-fire.
    func recordPairingFailed(reason: String, phase: String) {
        guard let method = pairingAttemptMethod else { return }
        var props: [String: AnalyticsValue] = [
            "method": .string(method),
            "reason": .string(reason),
            "failure_phase": .string(phase),
            "is_first_pair": .bool(pairingAttemptIsFirstPair),
            "attempt_id": .string(pairingAttemptID.uuidString),
        ]
        if let startedAt = pairingAttemptStartedAt {
            let ms = Int(((runtime?.now() ?? Date()).timeIntervalSince(startedAt)) * 1000)
            props["duration_ms"] = .int(max(0, ms))
        }
        analytics.capture("ios_pairing_failed", props)
        pairingAttemptStartedAt = nil
        pairingAttemptMethod = nil
    }

    func isCurrentPairingAttempt(_ attemptID: UUID) -> Bool {
        pairingAttemptID == attemptID && isSignedIn
    }

}
