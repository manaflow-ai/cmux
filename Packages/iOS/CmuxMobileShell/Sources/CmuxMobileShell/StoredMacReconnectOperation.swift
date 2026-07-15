import CMUXMobileCore
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation

@MainActor
struct StoredMacReconnectOperation {
    private typealias RouteCandidate = (route: CmxAttachRoute, displayName: String)
    private typealias DialResult = (
        success: StoredMacReconnectSuccess?,
        error: MobileShellConnectionError?
    )

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
    let persistPairedMac: @MainActor @Sendable (StoredMacReconnectPersistenceRequest) async -> Bool

    private var ownsFence: Bool {
        fence.isCurrent(fenceGeneration)
    }

    func run() async -> StoredMacReconnectOperationOutcome {
        guard ownsFence else { return .failed(error: nil, hasKnownPairedMac: nil) }
        let loadedActiveMac: MobilePairedMac?
        let loadedMacs: [MobilePairedMac]
        if loadsStoreSnapshot {
            if let refresher = store as? any PairedMacBackupRefreshing {
                await refresher.refreshFromBackup(stackUserID: scope.userID)
                guard ownsFence else { return .failed(error: nil, hasKnownPairedMac: nil) }
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
                return .failed(error: nil, hasKnownPairedMac: nil)
            }
        } else {
            loadedActiveMac = cachedMacs.first(where: \.isActive)
            loadedMacs = cachedMacs
        }
        guard ownsFence else { return .failed(error: nil, hasKnownPairedMac: nil) }

        var forgottenIDs = pendingForgottenIDs
        for key in forgottenScopeKeys {
            forgottenIDs.formUnion(await forgottenStore.load(scope: key))
            guard ownsFence else { return .failed(error: nil, hasKnownPairedMac: nil) }
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
                : .failed(error: nil, hasKnownPairedMac: true)
        }

        var lastError: MobileShellConnectionError?
        var authorizationError: MobileShellConnectionError?
        for mac in candidates {
            progress.targetMacDeviceID = mac.macDeviceID
            let localRoutes = routes(for: mac)
            for route in localRoutes {
                guard ownsFence else {
                    return .failed(error: nil, hasKnownPairedMac: nil)
                }
                let result = await dial(
                    mac: mac,
                    knownMacs: visibleMacs,
                    forgottenIDs: forgottenIDs,
                    route: route
                )
                if let success = result.success {
                    return .connected(success)
                }
                if let error = result.error {
                    lastError = error
                    if error.requiresReauthentication {
                        authorizationError = error
                    }
                }
            }
            if mac.macDeviceID == activeMac?.macDeviceID,
               let refreshedRoutes = await freshRoutes(
                   for: mac,
                   triedRoutes: localRoutes
                ) {
                for route in refreshedRoutes {
                    guard ownsFence else {
                        return .failed(error: nil, hasKnownPairedMac: nil)
                    }
                    let result = await dial(
                        mac: mac,
                        knownMacs: visibleMacs,
                        forgottenIDs: forgottenIDs,
                        route: route
                    )
                    if let success = result.success {
                        return .connected(success)
                    }
                    if let error = result.error {
                        lastError = error
                        if error.requiresReauthentication {
                            authorizationError = error
                        }
                    }
                }
            }
        }
        return .failed(error: authorizationError ?? lastError, hasKnownPairedMac: true)
    }

    private func routes(
        for mac: MobilePairedMac
    ) -> [RouteCandidate] {
        mac.routes.storedReconnectRoutes(
            supportedKinds: supportedKinds,
            preferNonLoopback: prefersNonLoopbackRoutes
        ).map { route in
            (route: route, displayName: displayName(for: route, mac: mac))
        }
    }

    private func displayName(for route: CmxAttachRoute, mac: MobilePairedMac) -> String {
        if let displayName = mac.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty {
            return displayName
        }
        if case let .hostPort(host, _) = route.endpoint {
            return host
        }
        return mac.macDeviceID
    }

    private func dial(
        mac: MobilePairedMac,
        knownMacs: [MobilePairedMac],
        forgottenIDs: Set<String>,
        route candidate: RouteCandidate
    ) async -> DialResult {
        guard let runtime else { return (nil, nil) }
        let route = candidate.route
        let ticket: CmxAttachTicket
        do {
            ticket = try await attachTicket(
                displayName: candidate.displayName,
                sourceMacDeviceID: mac.macDeviceID,
                route: route,
                runtime: runtime
            )
        } catch {
            return (nil, error as? MobileShellConnectionError)
        }
        let authority = StoredMacReconnectAuthority(
            ticket: ticket,
            sourceMac: mac,
            knownMacs: knownMacs,
            routeDisplayName: candidate.displayName
        )
        guard ownsFence,
              !forgottenIDs.contains(authority.macDeviceID),
              !progress.wasForgotten(authority.macDeviceID) else {
            return (nil, nil)
        }
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
                return (nil, nil)
            }
            let hostStatus = await requestHostStatus(on: client, runtime: runtime)
            let resolvedAuthority = authority.resolve(status: hostStatus)
            guard ownsFence, resolvedAuthority.accepted else {
                await client.disconnect()
                return (nil, nil)
            }
            let resolvedTicket = ticketAdoptingMacDeviceID(
                ticket,
                adoptingMacDeviceID: authority.macDeviceID
            )
            if persistsPairedMac {
                let accepted = await persistPairedMac(StoredMacReconnectPersistenceRequest(
                    ticket: resolvedTicket,
                    sourceMacDeviceID: mac.macDeviceID,
                    storedAuthorityMac: authority.storedMac,
                    displayName: hostStatus?.macDisplayName,
                    reportedInstanceTag: hostStatus?.macInstanceTag,
                    resolvedInstanceTag: resolvedAuthority.instanceTag
                ))
                guard accepted, ownsFence else {
                    await client.disconnect()
                    return (nil, nil)
                }
            }
            let registryMac = authority.registryMac(
                ticket: resolvedTicket,
                status: hostStatus,
                scope: scope,
                resolvedInstanceTag: resolvedAuthority.instanceTag
            )
            return (StoredMacReconnectSuccess(
                client: client,
                ticket: resolvedTicket,
                route: route,
                workspaceResponse: workspaceResponse,
                hostStatus: hostStatus,
                resolvedInstanceTag: resolvedAuthority.instanceTag,
                sourceMacDeviceID: mac.macDeviceID,
                foregroundMacDeviceID: authority.macDeviceID,
                registryMac: registryMac,
                scope: scope,
                displayName: authority.displayName(status: hostStatus),
                persistsPairedMac: persistsPairedMac
            ), nil)
        } catch {
            await client.disconnect()
            return (nil, error as? MobileShellConnectionError)
        }
    }

    private func attachTicket(
        displayName: String,
        sourceMacDeviceID: String,
        route: CmxAttachRoute,
        runtime: any MobileSyncRuntime
    ) async throws -> CmxAttachTicket {
        if route.kind == .iroh {
            return try storedMacTicket(
                displayName: displayName,
                macDeviceID: sourceMacDeviceID,
                routes: [route]
            )
        }
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

    private func storedMacTicket(
        displayName: String,
        macDeviceID: String,
        routes: [CmxAttachRoute]
    ) throws -> CmxAttachTicket {
        try CmxAttachTicket(
            workspaceID: "stored-workspace",
            terminalID: nil,
            macDeviceID: macDeviceID,
            macDisplayName: displayName,
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            routes: routes
        )
    }

    private func ticketAdoptingMacDeviceID(
        _ ticket: CmxAttachTicket,
        adoptingMacDeviceID macDeviceID: String
    ) -> CmxAttachTicket {
        let resolvedMacDeviceID = macDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedMacDeviceID.isEmpty,
              ticket.macDeviceID != resolvedMacDeviceID,
              let adopted = try? CmxAttachTicket(
                  version: ticket.version,
                  workspaceID: ticket.workspaceID,
                  terminalID: ticket.terminalID,
                  macDeviceID: resolvedMacDeviceID,
                  macDisplayName: ticket.macDisplayName,
                  macUserEmail: ticket.macUserEmail,
                  macUserID: ticket.macUserID,
                  macPairingCompatibilityVersion: ticket.macPairingCompatibilityVersion,
                  macAppVersion: ticket.macAppVersion,
                  macAppBuild: ticket.macAppBuild,
                  routes: ticket.routes,
                  expiresAt: ticket.expiresAt,
                  authToken: ticket.authToken
              ) else {
            return ticket
        }
        return adopted
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

    private func freshRoutes(
        for mac: MobilePairedMac,
        triedRoutes: [RouteCandidate]
    ) async -> [RouteCandidate]? {
        let localRoutes = routes(for: mac)
        let requiresIroh = localRoutes.contains { $0.route.kind == .iroh }
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
        let storedRoutes = updatedRoutes.storedReconnectRoutes(
            supportedKinds: supportedKinds,
            preferNonLoopback: prefersNonLoopbackRoutes
        )
        if storedRoutes.contains(where: { $0.kind == .iroh }) {
            let refreshed = storedRoutes.map { route in
                (route: route, displayName: displayName(for: route, mac: currentMac))
            }
            return sameCandidates(refreshed, triedRoutes) ? nil : refreshed
        }
        guard !requiresIroh else { return nil }
        let refreshed = updatedRoutes.reconnectHostPortRoutes(
            supportedKinds: supportedKinds,
            preferNonLoopback: prefersNonLoopbackRoutes
        ).compactMap { candidate -> RouteCandidate? in
            updatedRoutes.first(where: { $0.id == candidate.routeID }).map {
                (route: $0, displayName: displayName(for: $0, mac: currentMac))
            }
        }
        guard !refreshed.isEmpty else { return nil }
        return sameCandidates(refreshed, triedRoutes) ? nil : refreshed
    }

    private func sameCandidates(
        _ lhs: [RouteCandidate],
        _ rhs: [RouteCandidate]
    ) -> Bool {
        Set(lhs.map(routeCandidateKey)) == Set(rhs.map(routeCandidateKey))
    }

    private func routeCandidateKey(_ candidate: RouteCandidate) -> String {
        let route = candidate.route
        switch route.endpoint {
        case let .hostPort(host, port):
            return "\(route.kind.rawValue):host:\(host)\u{1F}\(port)"
        case let .peer(id, relayHint, directAddrs, relayURL):
            return "\(route.kind.rawValue):peer:\(id)\u{1F}\(relayHint ?? "")\u{1F}\(directAddrs.joined(separator: ","))\u{1F}\(relayURL ?? "")"
        case let .url(url):
            return "\(route.kind.rawValue):url:\(url)"
        }
    }

}
