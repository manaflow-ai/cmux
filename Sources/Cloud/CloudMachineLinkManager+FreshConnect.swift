import Foundation

extension CloudMachineLinkManager {
    /// Attempt offsets from the first dial of a machine that was created moments
    /// ago: the daemon usually listens within a second of allocation, so the first
    /// attempts are close together, later ones spread out, and none pass the budget.
    nonisolated static func freshDialOffsets(budget: Duration) -> [Duration] {
        let fixed: [Duration] = [
            .zero, .milliseconds(150), .milliseconds(300), .milliseconds(500),
            .milliseconds(800), .milliseconds(1200), .milliseconds(1600), .milliseconds(2000)
        ]
        var offsets = fixed.filter { $0 <= budget }
        var next: Duration = .milliseconds(2500)
        var step: Duration = .milliseconds(600)
        while next <= budget {
            offsets.append(next)
            next += step
            step += .milliseconds(100)
        }
        return offsets
    }

    /// The create response proved a trusted listener: the next link dials
    /// `--carrier` from the stored marker with no control-plane call, exactly as
    /// after a first successful link. A real stored fingerprint keeps its key.
    func recordTrustedCarrier(machineID: String) {
        guard paths.deviceFingerprint(for: machineID) == nil else { return }
        paths.saveDeviceFingerprint(CloudTuiClientPaths.carrierDeviceMarker, for: machineID)
    }

    /// The bundled client's capability tokens, for a control-plane repair call.
    func clientCapabilities() -> [String] {
        guard let clientURL else { return [] }
        return resolvedClientCapabilities(clientURL: clientURL)
    }

    /// Links a machine created moments ago from the route its create response named.
    ///
    /// Unlike ``connected(machineID:)`` this ignores the retry backoff (the machine has
    /// never failed), dials the single given route (no address-family probe race), and
    /// bounds every attempt by `attemptTimeout` instead of the 60 s connect timeout: a
    /// daemon that is still starting is expected here, so a short attempt that fails
    /// is simply retried on ``freshDialOffsets(budget:)`` until the budget ends. Then
    /// `repair` (the attach endpoint) runs once and the returned route is dialed once
    /// more; its failure is the caller's.
    ///
    /// `dial` replaces the real link for tests; production leaves it nil.
    func connectFreshMachine(
        machineID: String,
        route: String?,
        session: String,
        budget: Duration = .seconds(8),
        attemptTimeout: Duration = .seconds(3),
        repair: (@Sendable () async throws -> String?)? = nil,
        dial: (@Sendable (String, Duration) async throws -> CloudMachineLink.Connected)? = nil
    ) async throws -> CloudMachineLink.Connected {
        guard isCloudEnabled() else {
            throw ManagerError.retryLater(String(
                localized: "cloud.feature.disabled",
                defaultValue: "Cloud Machines are temporarily unavailable."
            ))
        }
        if let link = links[machineID], await link.isConnected, let connected = await link.connected {
            return connected
        }
        if let inFlight = connecting[machineID] {
            return try await inFlight.value
        }
        guard let route = route ?? privateRoutes[machineID], IPNetworkPrefix.routeHost(route) != nil else {
            throw ManagerError.privateRouteRequired(machineID)
        }
        let dialer: @Sendable (String, Duration) async throws -> CloudMachineLink.Connected
        if let dial {
            dialer = dial
        } else {
            guard let clientURL else { throw ManagerError.clientMissing }
            guard resolvedClientCapabilities(clientURL: clientURL).contains(CloudTuiCommandLine.wireGuardHubCapability) else {
                throw ManagerError.wireGuardHubUnsupported
            }
            guard let hub else { throw ManagerError.wireGuardHubMissing }
            dialer = { route, timeout in
                try await self.dialFreshLink(
                    machineID: machineID, clientURL: clientURL, hub: hub, route: route, session: session, timeout: timeout
                )
            }
        }
        let correlationID = UUID().uuidString.lowercased()
        StartupBreadcrumbLog.append(
            "cloud.link.start",
            fields: ["machine": machineID, "knownDevice": "1", "correlation": correlationID, "outcome": "started"]
        )
#if DEBUG
        cmuxDebugLog("cloud.link.freshConnect machine=\(machineID) route=\(route) budget=\(budget)")
#endif
        let offsets = Self.freshDialOffsets(budget: budget)
        let task = Task<CloudMachineLink.Connected, Error> {
            let started = ContinuousClock.now
            var currentRoute = route
            var lastError: Error = CloudMachineLink.LinkError.timedOut
            var attempts = 0
            for offset in offsets {
                try Task.checkCancellation()
                let wait = offset - started.duration(to: .now)
                if wait > .zero { try await Task.sleep(for: wait) }
                attempts += 1
                do {
                    return try await dialer(currentRoute, attemptTimeout)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
#if DEBUG
                    cmuxDebugLog("cloud.link.freshAttempt machine=\(machineID) attempt=\(attempts) error=\(CloudMachineLink.errorText(error))")
#endif
                }
            }
            guard let repair else { throw lastError }
            try Task.checkCancellation()
            if let repaired = try await repair()?.trimmingCharacters(in: .whitespacesAndNewlines), !repaired.isEmpty {
                currentRoute = repaired
            }
            try Task.checkCancellation()
            return try await dialer(currentRoute, attemptTimeout)
        }
        connecting[machineID] = task
        defer { if connecting[machineID] == task { connecting[machineID] = nil } }
        do {
            let connected = try await task.value
            guard connecting[machineID] == task, !task.isCancelled, isCloudEnabled() else { throw CancellationError() }
            lastFailure[machineID] = nil
#if DEBUG
            cmuxDebugLog("cloud.link.connected machine=\(machineID) socket=\(connected.socketPath) fresh=1")
#endif
            StartupBreadcrumbLog.append(
                "cloud.link.connected",
                fields: ["machine": machineID, "session": connected.session, "correlation": correlationID, "outcome": "connected"]
            )
            pushHostTheme(machineID: machineID, socketPath: connected.socketPath)
            return connected
        } catch {
            guard connecting[machineID] == task else { throw error }
            let text = CloudMachineLink.errorText(error)
            lastFailure[machineID] = (Date(), text)
            links[machineID] = nil
#if DEBUG
            cmuxDebugLog("cloud.link.failed machine=\(machineID) fresh=1 error=\(String(reflecting: error)) text=\(text)")
#endif
            StartupBreadcrumbLog.append(
                "cloud.link.failed",
                fields: [
                    "machine": machineID,
                    "error": CloudDiagnosticFailure.classify(error).rawValue,
                    "correlation": correlationID,
                    "outcome": "failed"
                ]
            )
            throw error
        }
    }

    /// One real attempt: claim the hub, check the route is inside the tunnel, dial
    /// `--carrier`. A failed attempt releases the hub claim through the link.
    private func dialFreshLink(
        machineID: String,
        clientURL: URL,
        hub: CloudWireGuardHub,
        route: String,
        session: String,
        timeout: Duration
    ) async throws -> CloudMachineLink.Connected {
        let claim = try await CloudOperationContext.phase(.tunnel) { try await hub.acquire() }
        guard let host = IPNetworkPrefix.routeHost(route),
              CloudWireGuardHub.routesHost(host, enrolledRoutes: claim.ready.routes) else {
            await hub.release(claim.lease)
            throw ManagerError.privateRouteRequired(machineID)
        }
        let link = CloudMachineLink(machineID: machineID, clientURL: clientURL, paths: paths)
        store(link: link, for: machineID)
        do {
            let connected = try await link.connect(
                route: route,
                session: session,
                carrier: true,
                timeout: timeout,
                wireguardHubSocket: claim.ready.socketPath,
                releaseHubLease: { await hub.release(claim.lease) }
            )
            recordTrustedCarrier(machineID: machineID)
            return connected
        } catch {
            await link.disconnect()
            if links[machineID] === link { links[machineID] = nil }
            throw error
        }
    }
}
