internal import CMUXMobileCore
internal import CmuxMobilePairedMac
internal import Foundation
internal import OSLog

private let presenceRouteSyncLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "presence-route-sync"
)

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
                let knownMacs = self.pairedMacsForIdentityMatching
                if self.connectionState != .connected,
                   let activeMacID = self.pairedMacs.first(where: { $0.isActive })?.macDeviceID {
                    let activeIDs = Self.macDeviceIDsForLogicalPairedMac(
                        activeMacID,
                        in: knownMacs,
                        supportedKinds: self.runtime?.supportedRouteKinds ?? [],
                        preferNonLoopback: Self.prefersNonLoopbackRoutes
                    )
                    let hasOnlineAuthority = activeIDs.contains { deviceID in
                        let instanceTag = knownMacs.first { $0.macDeviceID == deviceID }?.instanceTag
                        return self.presenceMap.reconnectRouteAuthority(
                            deviceId: deviceID,
                            pairedMacInstanceTag: instanceTag
                        ) != nil
                    }
                    if hasOnlineAuthority {
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
        guard await !isForgottenMacDeviceID(deviceId, scope: scope) else { return false }
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
            _ = await removeStoredPairedMacIfForgotten(mac.macDeviceID, scope: scope)
            return true
        } catch {
            presenceRouteSyncLog.debug(
                "presence route upsert failed: \(String(describing: error), privacy: .public)"
            )
            return false
        }
    }
}
