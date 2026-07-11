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
                if self.pairedMacsForIdentityMatching.isEmpty {
                    await self.loadPairedMacs()
                }
                guard await self.isScopeCurrent(scope) else { return }
                for instance in hostInstances {
                    guard await self.isScopeCurrent(scope) else { return }
                    await self.applyPushedRoutes(from: instance, scope: scope)
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
    func applyPushedRoutes(from instance: PresenceInstance, scope: MobileShellScopeSnapshot) async {
        guard let routes = instance.routes, await isScopeCurrent(scope) else { return }
        let deviceId = instance.deviceId
        guard await !isForgottenMacDeviceID(deviceId, scope: scope) else { return }
        if let deviceIndex = registryDevices.firstIndex(where: { $0.deviceId == deviceId }),
           let instanceIndex = registryDevices[deviceIndex].instances
               .firstIndex(where: { $0.tag == instance.tag }) {
            registryDevices[deviceIndex].instances[instanceIndex].routes = routes
        }
        guard !routes.isEmpty,
              let pairedMacStore,
              let mac = try? await pairedMacStore.loadAll(
                  stackUserID: scope.userID,
                  teamID: scope.teamID
              ).first(where: { $0.macDeviceID == deviceId }),
              await isScopeCurrent(scope),
              presenceMap.reconnectRouteAuthority(
                  deviceId: deviceId,
                  pairedMacInstanceTag: mac.instanceTag
              )?.tag == instance.tag,
              let updated = DeviceRegistryService.selectReconnectRoutes(
                  local: mac.routes,
                  registry: routes
              ),
              await isScopeCurrent(scope) else { return }
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
            guard wrote else { return }
            guard await isScopeCurrent(scope) else { return }
            if await removeStoredPairedMacIfForgotten(mac.macDeviceID, scope: scope) { return }
            await loadPairedMacs()
        } catch {
            presenceRouteSyncLog.debug(
                "presence route upsert failed: \(String(describing: error), privacy: .public)"
            )
        }
    }
}
