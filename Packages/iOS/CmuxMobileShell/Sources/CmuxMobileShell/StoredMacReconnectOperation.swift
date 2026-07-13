import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation

@MainActor
struct StoredMacReconnectOperation {
    private typealias RouteCandidate = (route: CmxAttachRoute, host: String, port: Int)

    let runtime: (any MobileSyncRuntime)?
    let store: any MobilePairedMacStoring
    let forgottenStore: any PairedMacForgottenStoring
    let scope: MobileShellScopeSnapshot
    let generation: Int
    let fence: SynchronousGenerationBoundary
    let fenceGeneration: UInt64
    let progress: StoredMacReconnectProgress
    let connectAttemptRegistry: MobileRPCConnectAttemptRegistry
    let stackTokenGate: RPCStackTokenGate
    let stackTokenForceRefreshGate: RPCStackTokenGate
    let deviceRegistry: (any DeviceRegistryRefreshing)?
    let supportedKinds: [CmxAttachTransportKind]
    let prefersNonLoopbackRoutes: Bool
    let cachedMacs: [MobilePairedMac]
    let pendingForgottenIDs: Set<String>
    let forgottenScopeKeys: [String]
    let loadsStoreSnapshot: Bool
    let persistsPairedMac: Bool

    private var ownsFence: Bool {
        fence.isCurrent(fenceGeneration)
    }

    func run() async -> StoredMacReconnectOperationOutcome {
        guard ownsFence else { return .failed(hasKnownPairedMac: nil) }
        let loadedActiveMac: MobilePairedMac?
        let loadedMacs: [MobilePairedMac]
        if loadsStoreSnapshot {
            if let refresher = store as? any PairedMacBackupRefreshing {
                await refresher.refreshFromBackup(stackUserID: scope.userID)
                guard ownsFence else { return .failed(hasKnownPairedMac: nil) }
            }
            do {
                loadedActiveMac = try await store.activeMac(
                    stackUserID: scope.userID,
                    teamID: scope.teamID
                )
                loadedMacs = try await store.loadAll(
                    stackUserID: scope.userID,
                    teamID: scope.teamID
                )
            } catch {
                return .failed(hasKnownPairedMac: nil)
            }
        } else {
            loadedActiveMac = cachedMacs.first(where: \.isActive)
            loadedMacs = cachedMacs
        }
        guard ownsFence else { return .failed(hasKnownPairedMac: nil) }

        var forgottenIDs = pendingForgottenIDs
        for key in forgottenScopeKeys {
            forgottenIDs.formUnion(await forgottenStore.load(scope: key))
            guard ownsFence else { return .failed(hasKnownPairedMac: nil) }
        }
        let visibleMacs = loadedMacs.filter { !forgottenIDs.contains($0.macDeviceID) }
        let activeMac = loadedActiveMac.flatMap {
            forgottenIDs.contains($0.macDeviceID) ? nil : $0
        }
        var candidates: [MobilePairedMac] = []
        if let activeMac, !routes(for: activeMac).isEmpty {
            candidates.append(activeMac)
        }
        candidates.append(contentsOf: visibleMacs.filter { mac in
            mac.macDeviceID != activeMac?.macDeviceID && !routes(for: mac).isEmpty
        })
        guard !candidates.isEmpty else {
            guard loadsStoreSnapshot else {
                return .unavailable(
                    hasKnownPairedMac: visibleMacs.isEmpty ? nil : true
                )
            }
            return visibleMacs.isEmpty
                ? .unavailable(hasKnownPairedMac: false)
                : .failed(hasKnownPairedMac: true)
        }

        for mac in candidates {
            progress.targetMacDeviceID = mac.macDeviceID
            let localRoutes = routes(for: mac)
            for route in localRoutes {
                guard ownsFence else { return .failed(hasKnownPairedMac: nil) }
                if let success = await dial(mac: mac, route: route) {
                    return .connected(success)
                }
            }
            if mac.macDeviceID == activeMac?.macDeviceID,
               let refreshedRoutes = await freshRoutes(
                   for: mac,
                   triedRoutes: localRoutes
               ) {
                for route in refreshedRoutes {
                    guard ownsFence else { return .failed(hasKnownPairedMac: nil) }
                    if let success = await dial(mac: mac, route: route) {
                        return .connected(success)
                    }
                }
            }
        }
        return .failed(hasKnownPairedMac: true)
    }

    private func routes(
        for mac: MobilePairedMac
    ) -> [RouteCandidate] {
        MobileShellComposite.reconnectHostPortRoutes(
            mac.routes,
            supportedKinds: supportedKinds,
            preferNonLoopback: prefersNonLoopbackRoutes
        ).compactMap { candidate in
            mac.routes.first(where: { $0.id == candidate.routeID }).map {
                (route: $0, host: candidate.host, port: candidate.port)
            }
        }
    }

    private func dial(
        mac: MobilePairedMac,
        route candidate: RouteCandidate
    ) async -> StoredMacReconnectSuccess? {
        guard let runtime else { return nil }
        let route = candidate.route
        let ticket: CmxAttachTicket
        do {
            ticket = try await attachTicket(
                displayName: mac.displayName ?? candidate.host,
                sourceMacDeviceID: mac.macDeviceID,
                route: route,
                runtime: runtime
            )
        } catch {
            return nil
        }
        guard ownsFence else { return nil }
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: ticket,
            allowsStackAuthFallback: true,
            connectAttemptRegistry: connectAttemptRegistry,
            stackTokenGate: stackTokenGate,
            stackTokenForceRefreshGate: stackTokenForceRefreshGate
        )
        do {
            let workspaceData = try await client.sendRequest(
                MobileCoreRPCClient.requestData(method: "workspace.list", params: [:]),
                timeoutNanoseconds: runtime.pairingRequestTimeoutNanoseconds
            )
            let workspaceResponse = try MobileSyncWorkspaceListResponse.decode(workspaceData)
            guard ownsFence else {
                await client.disconnect()
                return nil
            }
            let hostStatus = await requestHostStatus(on: client, runtime: runtime)
            let authority = acceptedAuthority(for: mac, status: hostStatus)
            guard ownsFence, authority.accepted else {
                await client.disconnect()
                return nil
            }
            if persistsPairedMac {
                let accepted = await persist(
                    ticket: ticket,
                    sourceMac: mac,
                    displayName: hostStatus?.macDisplayName,
                    reportedInstanceTag: hostStatus?.macInstanceTag,
                    resolvedInstanceTag: authority.resolved
                )
                guard accepted, ownsFence else {
                    await client.disconnect()
                    return nil
                }
            }
            return StoredMacReconnectSuccess(
                client: client,
                ticket: ticket,
                route: route,
                workspaceResponse: workspaceResponse,
                hostStatus: hostStatus,
                resolvedInstanceTag: authority.resolved,
                sourceMacDeviceID: mac.macDeviceID,
                sourceMac: mac,
                scope: scope,
                displayName: hostStatus?.macDisplayName ?? mac.displayName ?? candidate.host,
                persistsPairedMac: persistsPairedMac
            )
        } catch {
            await client.disconnect()
            return nil
        }
    }

    private func attachTicket(
        displayName: String,
        sourceMacDeviceID: String,
        route: CmxAttachRoute,
        runtime: any MobileSyncRuntime
    ) async throws -> CmxAttachTicket {
        let probeTicket = try syntheticTicket(
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
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "mobile.attach_ticket.create",
                params: ["ttl_seconds": 3600, "scope": "mac", "target": "ticket_only"]
            )
            let data = try await client.sendRequest(
                request,
                timeoutNanoseconds: runtime.pairingRequestTimeoutNanoseconds
            )
            await client.disconnect()
            return try MobileManualAttachTicketCreateResponse.decode(data)
                .ticket
                .constrainingRoutes(to: [route], fallbackDisplayName: displayName)
        } catch {
            await client.disconnect()
            guard MobileShellComposite.shouldFallbackToSyntheticManualTicket(after: error) else {
                throw error
            }
            return try syntheticTicket(
                displayName: displayName,
                macDeviceID: "manual-\(sourceMacDeviceID)",
                route: route
            )
        }
    }

    private func syntheticTicket(
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

    private func requestHostStatus(
        on client: MobileCoreRPCClient,
        runtime: any MobileSyncRuntime
    ) async -> MobileHostStatusResponse? {
        do {
            let data = try await client.sendRequest(
                MobileCoreRPCClient.requestData(method: "mobile.host.status", params: [:]),
                timeoutNanoseconds: runtime.pairingRequestTimeoutNanoseconds
            )
            return try? MobileHostStatusResponse.decode(data)
        } catch {
            return nil
        }
    }

    private func acceptedAuthority(
        for mac: MobilePairedMac,
        status: MobileHostStatusResponse?
    ) -> (accepted: Bool, resolved: String?) {
        let reportedDeviceID = MobileMacInstanceTagAuthority.normalized(status?.macDeviceID)
        if let reportedDeviceID,
           !MobileMacInstanceTagAuthority.authenticatedDeviceMatches(
            reportedDeviceID: reportedDeviceID,
            expectedDeviceID: mac.macDeviceID
           ) {
            return (false, nil)
        }
        let expectation = MobileMacInstanceTagAuthority.expectation(
            storedInstanceTag: mac.instanceTag
        )
        if case .preserve = expectation, reportedDeviceID == nil {
            return (false, nil)
        }
        guard case .accept(let resolved) = MobileMacInstanceTagAuthority.resolve(
            expectation: expectation,
            reportedInstanceTag: status?.macInstanceTag
        ) else {
            return (false, nil)
        }
        return (true, resolved)
    }

    private func freshRoutes(
        for mac: MobilePairedMac,
        triedRoutes: [RouteCandidate]
    ) async -> [RouteCandidate]? {
        guard let deviceRegistry,
              ownsFence,
              !progress.wasForgotten(mac.macDeviceID),
              let registryRoutes = await deviceRegistry.freshRoutes(
                  forMacDeviceID: mac.macDeviceID,
                  instanceTag: mac.instanceTag
              ),
              ownsFence,
              !progress.wasForgotten(mac.macDeviceID),
              let currentMac = try? await store.loadAll(
                  stackUserID: scope.userID,
                  teamID: scope.teamID
              ).first(where: { $0.macDeviceID == mac.macDeviceID }),
              ownsFence,
              !progress.wasForgotten(mac.macDeviceID),
              currentMac.instanceTag == mac.instanceTag,
              let updatedRoutes = DeviceRegistryService.selectReconnectRoutes(
                  local: mac.routes,
                  registry: registryRoutes
              ) else {
            return nil
        }
        let refreshed = MobileShellComposite.reconnectHostPortRoutes(
            updatedRoutes,
            supportedKinds: supportedKinds,
            preferNonLoopback: prefersNonLoopbackRoutes
        ).compactMap { candidate in
            updatedRoutes.first(where: { $0.id == candidate.routeID }).map {
                (route: $0, host: candidate.host, port: candidate.port)
            }
        }
        guard !refreshed.isEmpty else { return nil }
        let tried = Set(triedRoutes.map { "\($0.host)\u{1F}\($0.port)" })
        let fresh = Set(refreshed.map { "\($0.host)\u{1F}\($0.port)" })
        return fresh == tried ? nil : refreshed
    }

    private func persist(
        ticket: CmxAttachTicket,
        sourceMac: MobilePairedMac,
        displayName: String?,
        reportedInstanceTag: String?,
        resolvedInstanceTag: String?
    ) async -> Bool {
        guard !ticket.macDeviceID.isEmpty,
              ticket.macDeviceID != "manual-ticket-request",
              !ticket.macDeviceID.hasPrefix("manual-") else {
            return true
        }
        let scopedMacs = (try? await store.loadAll(
            stackUserID: scope.userID,
            teamID: scope.teamID
        )) ?? []
        guard ownsFence else { return false }
        let matchingMacs = scopedMacs.filter { $0.macDeviceID == ticket.macDeviceID }
        let existing = matchingMacs.first {
            $0.stackUserID == scope.userID && $0.teamID == scope.teamID
        }
        let fallback = existing
            ?? matchingMacs.first { $0.stackUserID == scope.userID }
            ?? matchingMacs.first
        let previousActive = try? await store.activeMac(
            stackUserID: scope.userID,
            teamID: scope.teamID
        )
        guard ownsFence else { return false }
        let authorityUnchanged = resolvedInstanceTag == existing?.instanceTag
        let routes = authorityUnchanged && ticket.routes.count == 1 && !(fallback?.routes.isEmpty ?? true)
            ? MobileShellComposite.mergedReconnectRoutes(
                ticketRoutes: ticket.routes,
                storedRoutes: fallback?.routes ?? []
            )
            : ticket.routes
        do {
            let accepted: Bool
            if reportedInstanceTag == nil, sourceMac.instanceTag == nil {
                accepted = try await store.upsertRoutesIfAuthorized(
                    macDeviceID: ticket.macDeviceID,
                    displayName: displayName ?? fallback?.displayName,
                    routes: routes,
                    condition: .unclaimed,
                    markActive: true,
                    stackUserID: scope.userID,
                    teamID: scope.teamID,
                    now: Date()
                )
            } else {
                try await store.upsert(
                    macDeviceID: ticket.macDeviceID,
                    displayName: displayName ?? fallback?.displayName,
                    routes: routes,
                    instanceTag: resolvedInstanceTag ?? existing?.instanceTag,
                    markActive: true,
                    stackUserID: scope.userID,
                    teamID: scope.teamID,
                    now: Date()
                )
                accepted = true
            }
            guard accepted else { return false }
            guard !ownsFence else { return true }
            await rollback(
                persistedMacDeviceID: ticket.macDeviceID,
                previousPersistedMac: existing,
                previousActiveMac: previousActive
            )
            return false
        } catch {
            return false
        }
    }

    private func rollback(
        persistedMacDeviceID: String,
        previousPersistedMac: MobilePairedMac?,
        previousActiveMac: MobilePairedMac?
    ) async {
        do {
            if progress.wasForgotten(persistedMacDeviceID)
                || progress.wasForgotten(previousPersistedMac?.macDeviceID ?? "") {
                try await store.remove(
                    macDeviceID: persistedMacDeviceID,
                    stackUserID: scope.userID,
                    teamID: scope.teamID
                )
            } else if let previousPersistedMac {
                try await store.upsert(
                    macDeviceID: previousPersistedMac.macDeviceID,
                    displayName: previousPersistedMac.displayName,
                    routes: previousPersistedMac.routes,
                    instanceTag: previousPersistedMac.instanceTag,
                    markActive: previousPersistedMac.isActive,
                    stackUserID: previousPersistedMac.stackUserID,
                    teamID: previousPersistedMac.teamID,
                    now: previousPersistedMac.lastSeenAt
                )
            } else {
                try await store.remove(
                    macDeviceID: persistedMacDeviceID,
                    stackUserID: scope.userID,
                    teamID: scope.teamID
                )
            }
            if let previousActiveMac,
               previousActiveMac.macDeviceID != persistedMacDeviceID {
                try await store.setActive(
                    macDeviceID: previousActiveMac.macDeviceID,
                    stackUserID: scope.userID,
                    teamID: scope.teamID
                )
            }
        } catch {}
    }
}
