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
    func syncPushedRoutes(from instance: PresenceInstance, scope: MobileShellScopeSnapshot) {
        syncPushedRoutes(from: [instance], scope: scope)
    }

    /// Serializes every host instance in one delivery so registry state and
    /// recovery signals stay current even when route persistence has no authority.
    func syncPushedRoutes(from instances: [PresenceInstance], scope: MobileShellScopeSnapshot) {
        let hostInstances = instances.filter { $0.platform.lowercased() != "ios" }
        guard !hostInstances.isEmpty else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performSerializedPairedMacWrite(ifStillCurrent: nil) { [weak self] in
                guard let self, await self.isScopeCurrent(scope) else { return }
                // Presence can arrive after another path paired or restored a Mac
                // without refreshing this shell's display cache. Take one scoped
                // store snapshot per delivery so every host is matched against the
                // current authority set without doing a database scan per instance.
                await self.loadPairedMacs()
                guard await self.isScopeCurrent(scope) else { return }
                let pairedMacsByDeviceID = Dictionary(
                    self.pairedMacsForIdentityMatching.map { ($0.macDeviceID, $0) },
                    uniquingKeysWith: { current, candidate in
                        current.lastSeenAt >= candidate.lastSeenAt ? current : candidate
                    }
                )
                var persistedRoutes = false
                for instance in hostInstances {
                    guard await self.isScopeCurrent(scope) else { return }
                    if await self.applyPushedRoutes(
                        from: instance,
                        pairedMac: pairedMacsByDeviceID[instance.deviceId],
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
                    let reconnectEvidence = self.presenceMap
                        .allInstancesForReconnectEvidence()
                        .filter { $0.platform.lowercased() != "ios" }
                        .map(MobilePresenceReconnectEvidence.init)
                    let evidenceChanged = self.lastPresenceReconnectEvidence?.scope != scope
                        || self.lastPresenceReconnectEvidence?.instances != reconnectEvidence
                    self.lastPresenceReconnectEvidence = (scope, reconnectEvidence)
                    var shouldRecover = self.personalIrohDiscovery != nil
                    if let activeMac = self.pairedMacs.first(where: { $0.isActive }) {
                        let activeIDs = self.pairedMacAliasIDs(
                            for: activeMac.macDeviceID,
                            instanceTag: activeMac.instanceTag
                        )
                        shouldRecover = shouldRecover || activeIDs.contains { deviceID in
                            self.presenceMap.reconnectRouteAuthority(
                                deviceId: deviceID,
                                pairedMacInstanceTag: activeMac.instanceTag
                            ) != nil
                        }
                    }
                    if shouldRecover {
                        if evidenceChanged {
                            self.clearTransientAutomaticReconnectBackoff(
                                accountID: scope.userID
                            )
                        }
                        // Presence is only a wake-up signal. The recovery pass
                        // still obtains first-pair candidates from the
                        // authenticated personal broker.
                        self.recoverMobileConnection(trigger: .presencePush)
                    }
                }
            }
        }
        pushedRouteSyncTask = task
    }

    /// Updates live registry routes, then persists only a nonempty authority payload.
    func applyPushedRoutes(
        from instance: PresenceInstance,
        pairedMac: MobilePairedMac?,
        scope: MobileShellScopeSnapshot
    ) async -> Bool {
        guard let routes = instance.routes, await isScopeCurrent(scope) else { return false }
        let deviceId = instance.deviceId
        guard await !isForgottenMacDeviceID(
            deviceId,
            instanceTag: instance.tag,
            scope: scope
        ) else { return false }
        if let deviceIndex = registryDevices.firstIndex(where: { $0.deviceId == deviceId }),
           let instanceIndex = registryDevices[deviceIndex].instances
               .firstIndex(where: { $0.tag == instance.tag }) {
            registryDevices[deviceIndex].instances[instanceIndex].routes = routes
        }
        guard !routes.isEmpty,
              let pairedMacStore,
              let mac = pairedMac,
              await isScopeCurrent(scope),
              presenceMap.reconnectRouteAuthority(
                  deviceId: deviceId,
                  pairedMacInstanceTag: mac.instanceTag
              )?.tag == instance.tag,
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
            guard await isScopeCurrent(scope) else { return true }
            _ = await removeStoredPairedMacIfForgotten(
                mac.macDeviceID,
                instanceTag: mac.instanceTag,
                scope: scope
            )
            return true
        } catch {
            presenceRouteSyncLog.debug(
                "presence route upsert failed: \(String(describing: error), privacy: .public)"
            )
            return false
        }
    }
}
