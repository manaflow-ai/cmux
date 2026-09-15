public import CMUXMobileCore
import CmuxMobileDiagnostics
import CmuxMobilePairedMac
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation

@MainActor
extension MobileShellComposite {
    private func suggestionClient(for key: MacPairingKey) -> MobileCoreRPCClient? {
        if connectionState == .connected, let connectedMacDeviceID,
           MacPairingKey(macDeviceID: connectedMacDeviceID, instanceTag: connectedMacInstanceTag) == key {
            return remoteClient
        }
        return secondaryMacSubscriptions[key]?.client
    }

    /// Receives hints only from a live session whose authenticated identity matches the requested Computer.
    func cacheTailscaleSuggestions(
        _ status: MobileHostStatusResponse, client: MobileCoreRPCClient,
        scopeGeneration: Int
    ) async {
        guard let deviceID = status.macDeviceID, !deviceID.isEmpty,
              scopeGeneration == secondaryAggregationScopeGeneration,
              let scope = await currentScopeSnapshot(), scope.generation == scopeGeneration else { return }
        let key = MacPairingKey(macDeviceID: deviceID, instanceTag: status.macInstanceTag)
        guard suggestionClient(for: key) === client, await isScopeCurrent(scope),
              suggestionClient(for: key) === client else { return }
        tailscaleSuggestionCache.record(status.routes, for: key, scope: scope, now: appDiagnosticNow())
    }

    /// Route announcements are also retained in the scoped paired-Mac and
    /// device-registry snapshots. They remain suggestions until the user
    /// accepts them, so filter out only the local grant table, not every route
    /// already present in the reconnect snapshot.
    private func storedTailscaleSuggestions(
        for key: MacPairingKey,
        cachedRoutes: [CmxAttachRoute]
    ) -> [CmxAttachRoute] {
        let pairedMac = storedPairedMacsIncludingHidden.first {
            MacPairingKey($0) == key
        }
        let registryRoutes = registryDevices
            .first { cmxCanonicalDeviceID($0.deviceId) == key.canonicalMacDeviceID }?
            .instances
            .first { MacPairingKey(macDeviceID: key.canonicalMacDeviceID, instanceTag: $0.tag) == key }?
            .routes ?? []
        let announcedRoutes = cachedRoutes + (pairedMac?.routes ?? []) + registryRoutes
        let acceptedRoutes = pairedMac?.legacyTailscaleRoutes ?? []
        let candidates = announcedRoutes.filter { route in
            route.kind == .tailscale
                && !acceptedRoutes.contains(where: {
                    $0.kind == route.kind && $0.endpoint == route.endpoint
                })
        }
        return MobileComputerRouteGroup.suggestions(candidates).flatMap(\.routes)
    }

    /// Refreshes through an existing connection and returns recent device-local hints when offline.
    /// This never opens another route or grants permission to dial a suggested address.
    public func tailscaleRouteSuggestions(macDeviceID: String, instanceTag: String?) async -> [CmxAttachRoute] {
        guard let scope = await currentScopeSnapshot() else { return [] }
        await loadPairedMacs()
        guard await isScopeCurrent(scope) else { return [] }
        let key = MacPairingKey(macDeviceID: macDeviceID, instanceTag: instanceTag)
        if let client = suggestionClient(for: key),
           let data = try? await client.sendRequest(
               MobileCoreRPCClient.requestData(method: "mobile.host.status", params: [:]),
               timeoutNanoseconds: 3_000_000_000
           ), let response = try? MobileHostStatusResponse.decode(data),
           response.macDeviceID == key.canonicalMacDeviceID,
           MacPairingKey(macDeviceID: macDeviceID, instanceTag: response.macInstanceTag) == key,
           await isScopeCurrent(scope), suggestionClient(for: key) === client {
            tailscaleSuggestionCache.record(response.routes, for: key, scope: scope, now: appDiagnosticNow())
        }
        guard await isScopeCurrent(scope) else { return [] }
        let cachedRoutes = tailscaleSuggestionCache
            .groups(for: key, scope: scope, now: appDiagnosticNow())
            .flatMap(\.routes)
        let suggestions = storedTailscaleSuggestions(for: key, cachedRoutes: cachedRoutes)
        let storedCount = storedPairedMacsIncludingHidden.first {
            MacPairingKey($0) == key
        }?.routes.count ?? 0
        let registryCount = registryDevices
            .first { cmxCanonicalDeviceID($0.deviceId) == key.canonicalMacDeviceID }?
            .instances
            .first { MacPairingKey(macDeviceID: key.canonicalMacDeviceID, instanceTag: $0.tag) == key }?
            .routes.count ?? 0
        MobileDebugLog.anchormux(
            "tailscale.suggestions key=\(key.canonicalMacDeviceID.prefix(8)) live=\(suggestionClient(for: key) != nil) cache=\(cachedRoutes.count) stored=\(storedCount) registry=\(registryCount) returned=\(suggestions.count)"
        )
        return suggestions
    }

    /// Adds one complete group from this account's authenticated hint cache.
    /// The local transaction retains Iroh and every previously accepted Tailscale destination.
    @discardableResult
    public func acceptTailscaleRouteSuggestions(
        _ routes: [CmxAttachRoute], macDeviceID: String, instanceTag: String?
    ) async -> Bool {
        guard !routes.isEmpty, let pairedMacStore, let scope = await currentScopeSnapshot() else { return false }
        let key = MacPairingKey(macDeviceID: macDeviceID, instanceTag: instanceTag)
        // UI input alone cannot manufacture a route capability. Use the exact
        // scoped announcement, whether it came from the live cache or the
        // persisted registry snapshot, never metadata supplied by an action caller.
        let cachedRoutes = tailscaleSuggestionCache
            .groups(for: key, scope: scope, now: appDiagnosticNow())
            .flatMap(\.routes)
        let availableGroups = MobileComputerRouteGroup.groups(
            storedTailscaleSuggestions(for: key, cachedRoutes: cachedRoutes)
        )
        guard let group = availableGroups
            .first(where: { $0.routes == routes }) else { return false }
        var wrote = false
        await performSerializedPairedMacWrite(ifStillCurrent: nil) {
            guard await self.isScopeCurrent(scope),
                  MobileComputerRouteGroup.groups(
                      self.storedTailscaleSuggestions(
                          for: key,
                          cachedRoutes: self.tailscaleSuggestionCache
                              .groups(for: key, scope: scope, now: self.appDiagnosticNow())
                              .flatMap(\.routes)
                      )
                  ).contains(group) else { return }
            do {
                let rows = try await pairedMacStore.loadAll(stackUserID: scope.userID, teamID: scope.teamID)
                guard let mac = rows.first(where: { MacPairingKey($0) == key }),
                      await self.isScopeCurrent(scope) else { return }
                try await pairedMacStore.authorizeUserTailscaleRoutes(
                    macDeviceID: mac.macDeviceID, instanceTag: mac.instanceTag,
                    stackUserID: mac.stackUserID ?? scope.userID, teamID: mac.teamID,
                    routes: group.routes, replacingExistingRoutes: false
                )
                guard await self.isScopeCurrent(scope) else { return }
                let saved = try await pairedMacStore.loadAll(stackUserID: scope.userID, teamID: scope.teamID)
                    .first(where: { MacPairingKey($0) == key })
                wrote = group.routes.allSatisfy { route in
                    saved?.routes.contains(where: { $0.kind == route.kind && $0.endpoint == route.endpoint }) == true
                        && saved?.legacyTailscaleRoutes?.contains(where: { $0.endpoint == route.endpoint }) == true
                }
            } catch { wrote = false }
        }
        guard wrote, await isScopeCurrent(scope) else { return false }
        await loadPairedMacs()
        if connectionMethod(forMacDeviceID: macDeviceID, instanceTag: instanceTag) == .tailscale {
            recoverMobileConnection(trigger: .connectionMethodChanged)
        }
        return true
    }
}
