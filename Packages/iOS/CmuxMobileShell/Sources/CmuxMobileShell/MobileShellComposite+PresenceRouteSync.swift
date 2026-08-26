internal import CMUXMobileCore
internal import CmuxMobilePairedMac
internal import Foundation
internal import OSLog

private let presenceRouteSyncLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "presence-route-sync"
)

struct MobilePresenceReconnectEvidence: Equatable, Sendable {
    struct Hint: Equatable, Sendable {
        let kind: String
        let value: String
        let source: String
        let privacyScope: String
        let networkProfileSource: String?
        let networkProfileID: String?
    }

    enum Endpoint: Equatable, Sendable {
        case hostPort(host: String, port: Int)
        case peer(identity: String, hints: [Hint])
        case url(String)
    }

    struct Route: Equatable, Sendable {
        let id: String
        let kind: String
        let endpoint: Endpoint
        let priority: Int
    }

    let deviceID: String
    let tag: String
    let online: Bool
    let onlineSince: Double?
    let routes: [Route]?

    init(_ instance: PresenceInstance) {
        deviceID = instance.deviceId
        tag = instance.tag
        online = instance.online
        onlineSince = instance.onlineSince
        routes = instance.routes?.map { route in
            let endpoint: Endpoint = switch route.endpoint {
            case let .hostPort(host, port):
                .hostPort(host: host, port: port)
            case let .peer(identity, hints):
                .peer(
                    identity: identity.endpointID,
                    hints: hints.map { hint in
                        Hint(
                            kind: hint.kind.rawValue,
                            value: hint.value,
                            source: hint.source.rawValue,
                            privacyScope: hint.privacyScope.rawValue,
                            networkProfileSource: hint.networkProfile?.source.rawValue,
                            networkProfileID: hint.networkProfile?.profileID
                        )
                    }
                )
            case let .url(url):
                .url(url)
            }
            return Route(
                id: route.id,
                kind: route.kind.rawValue,
                endpoint: endpoint,
                priority: route.priority
            )
        }
    }
}

@MainActor
extension MobileShellComposite {
    /// Writes one presence instance through its paired Mac's route authority.
    @discardableResult
    func syncPushedRoutes(
        from instance: PresenceInstance,
        scope: MobileShellScopeSnapshot
    ) -> Task<Void, Never>? {
        syncPushedRoutes(from: [instance], scope: scope)
    }

    /// Serializes every host instance in one delivery so registry state and
    /// recovery signals stay current even when route persistence has no authority.
    @discardableResult
    func syncPushedRoutes(
        from instances: [PresenceInstance],
        scope: MobileShellScopeSnapshot
    ) -> Task<Void, Never>? {
        let hostInstances = instances.filter { $0.platform.lowercased() != "ios" }
        guard !hostInstances.isEmpty else { return nil }
        if let currentScope = pushedRouteSyncScope,
           currentScope != scope {
            pushedRouteSyncOperationID = UUID()
            pushedRouteSyncTask?.cancel()
            pushedRouteSyncTask = nil
            pushedRouteSyncPendingInstances = [:]
        }
        pushedRouteSyncScope = scope
        for instance in hostInstances {
            let key = CmxMacAppInstanceIdentity(
                macDeviceID: instance.deviceId,
                instanceTag: instance.tag
            ).id
            pushedRouteSyncPendingInstances[key] = instance
        }
        if let pushedRouteSyncTask {
            return pushedRouteSyncTask
        }
        let operationID = UUID()
        pushedRouteSyncOperationID = operationID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.pushedRouteSyncOperationID == operationID {
                    self.pushedRouteSyncTask = nil
                    self.pushedRouteSyncOperationID = nil
                    self.pushedRouteSyncScope = nil
                    self.pushedRouteSyncPendingInstances = [:]
                }
            }
            while !Task.isCancelled,
                  self.pushedRouteSyncOperationID == operationID {
                let batch = self.pushedRouteSyncPendingInstances.values.sorted {
                    let lhsID = cmxCanonicalDeviceID($0.deviceId)
                    let rhsID = cmxCanonicalDeviceID($1.deviceId)
                    if lhsID != rhsID { return lhsID < rhsID }
                    return $0.tag < $1.tag
                }
                self.pushedRouteSyncPendingInstances = [:]
                guard !batch.isEmpty else { return }
                await self.performPushedRouteSyncBatch(
                    batch,
                    scope: scope
                )
                guard await self.isScopeCurrent(scope) else { return }
                if self.pushedRouteSyncPendingInstances.isEmpty { return }
            }
        }
        pushedRouteSyncTask = task
        return task
    }

    private func performPushedRouteSyncBatch(
        _ hostInstances: [PresenceInstance],
        scope: MobileShellScopeSnapshot
    ) async {
        // A route push is broker-grade evidence that the Mac's endpoint state
        // changed (relaunch, re-registration). Drop any reusable transport
        // discovery snapshot for those Macs before recovery dials, so the
        // next dial rebuilds its plan from a fresh broker fetch instead of
        // redialing corpse route state (docs/transport-plane.md, D5).
        if let personalIrohDiscovery {
            var invalidatedDeviceIDs = Set<String>()
            for instance in hostInstances where instance.routes?.isEmpty == false {
                let deviceID = cmxCanonicalDeviceID(instance.deviceId)
                guard invalidatedDeviceIDs.insert(deviceID).inserted else {
                    continue
                }
                await personalIrohDiscovery.invalidateDiscovery(
                    forMacDeviceID: instance.deviceId
                )
            }
        }
        await performSerializedPairedMacWrite(ifStillCurrent: nil) { [weak self] in
            guard let self, await self.isScopeCurrent(scope) else { return }
            // Presence can arrive after another path paired or restored a Mac
            // without refreshing this shell's display cache. Take one scoped
            // store snapshot per batch so every host is matched against current
            // authority without a database scan per instance.
            await self.loadPairedMacs()
            guard await self.isScopeCurrent(scope) else { return }
            let pairedMacsByPairingID = Dictionary(
                self.storedPairedMacsIncludingHidden.map {
                    ($0.id, $0)
                },
                uniquingKeysWith: { current, candidate in
                    current.lastSeenAt >= candidate.lastSeenAt
                        ? current : candidate
                }
            )
            var persistedRoutes = false
            for instance in hostInstances {
                guard await self.isScopeCurrent(scope) else { return }
                let pairingID = MobilePairedMac.pairingID(
                    macDeviceID: instance.deviceId,
                    instanceTag: instance.tag
                )
                if await self.applyPushedRoutes(
                    from: instance,
                    pairedMac: pairedMacsByPairingID[pairingID],
                    scope: scope
                ) {
                    persistedRoutes = true
                }
            }
            guard await self.isScopeCurrent(scope) else { return }
            if persistedRoutes {
                await self.loadPairedMacs()
            }
            guard await self.isScopeCurrent(scope) else { return }
            if self.connectionState != .connected {
                self.recoverFromPushedRouteBatch(scope: scope)
            }
        }
    }

    private func recoverFromPushedRouteBatch(
        scope: MobileShellScopeSnapshot
    ) {
        let reconnectEvidence = presenceMap
            .allInstancesForReconnectEvidence()
            .filter { $0.platform.lowercased() != "ios" }
            .map(MobilePresenceReconnectEvidence.init)
        let evidenceChanged = lastPresenceReconnectEvidence?.scope != scope
            || lastPresenceReconnectEvidence?.instances != reconnectEvidence
        lastPresenceReconnectEvidence = (scope, reconnectEvidence)
        var shouldRecover = personalIrohDiscovery != nil
        if let activeMac = pairedMacs.first(where: { $0.isActive }) {
            let activeIDs = pairedMacAliasIDs(
                for: activeMac.macDeviceID,
                instanceTag: activeMac.instanceTag
            )
            shouldRecover = shouldRecover || activeIDs.contains { deviceID in
                presenceMap.reconnectRouteAuthority(
                    deviceId: deviceID,
                    pairedMacInstanceTag: activeMac.instanceTag
                ) != nil
            }
        }
        guard shouldRecover else { return }
        if evidenceChanged {
            clearTransientAutomaticReconnectBackoff(
                accountID: scope.userID
            )
        }
        // Presence is only a wake-up signal. The recovery pass still obtains
        // first-pair candidates from the authenticated personal broker.
        // Unchanged heartbeats are throttled so a persistent outage cannot
        // restart an in-flight recovery on the presence cadence.
        guard presencePushRecoveryThrottle.shouldRecover(
            evidenceChanged: evidenceChanged,
            now: runtime?.now() ?? Date()
        ) else {
            return
        }
        recoverMobileConnection(trigger: .presencePush)
    }

    /// Updates live registry routes, then persists only a nonempty authority payload.
    func applyPushedRoutes(
        from instance: PresenceInstance,
        pairedMac: MobilePairedMac?,
        scope: MobileShellScopeSnapshot
    ) async -> Bool {
        guard let routes = instance.routes, await isScopeCurrent(scope) else { return false }
        let deviceId = instance.deviceId
        if let deviceIndex = registryDevices.firstIndex(where: { $0.deviceId == deviceId }),
           let instanceIndex = registryDevices[deviceIndex].instances
               .firstIndex(where: {
                   CmxMacAppInstanceIdentity(
                       macDeviceID: deviceId,
                       instanceTag: $0.tag
                   ).id == CmxMacAppInstanceIdentity(
                       macDeviceID: deviceId,
                       instanceTag: instance.tag
                   ).id
               }) {
            registryDevices[deviceIndex].instances[instanceIndex].routes = routes
        }
        guard !routes.isEmpty,
              let pairedMacStore,
              let mac = pairedMac,
              await isScopeCurrent(scope),
              presenceMap.reconnectRouteAuthority(
                deviceId: deviceId,
                pairedMacInstanceTag: mac.instanceTag
              ).map({ authority in
                  CmxMacAppInstanceIdentity(
                      macDeviceID: deviceId,
                      instanceTag: authority.tag
                  ).id
              }) == CmxMacAppInstanceIdentity(
                  macDeviceID: deviceId,
                  instanceTag: instance.tag
              ).id,
              let updated = DeviceRegistryService.selectReconnectRoutes(
                  local: mac.routes,
                  registry: routes
              ),
              await isScopeCurrent(scope) else { return false }
        do {
            let wrote = try await pairedMacStore.upsertRoutesIfAuthorized(
                macDeviceID: mac.macDeviceID,
                displayName: mac.displayName,
                routes: updated,
                condition: .matchingInstanceTag(mac.instanceTag),
                markActive: nil,
                stackUserID: scope.userID,
                teamID: scope.teamID,
                now: Date()
            )
            guard wrote else { return false }
            return true
        } catch {
            presenceRouteSyncLog.debug(
                "presence route upsert failed: \(String(describing: error), privacy: .public)"
            )
            return false
        }
    }
}
