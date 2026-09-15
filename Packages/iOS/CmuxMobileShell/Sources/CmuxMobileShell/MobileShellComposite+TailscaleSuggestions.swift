public import CMUXMobileCore
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

    /// Refreshes through an existing connection and returns recent device-local hints when offline.
    /// This never opens another route or grants permission to dial a suggested address.
    public func tailscaleRouteSuggestions(macDeviceID: String, instanceTag: String?) async -> [CmxAttachRoute] {
        guard let scope = await currentScopeSnapshot() else { return [] }
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
        return tailscaleSuggestionCache.groups(for: key, scope: scope, now: appDiagnosticNow()).flatMap(\.routes)
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
        // cached group's values, never metadata supplied by an action caller.
        guard let group = tailscaleSuggestionCache.groups(for: key, scope: scope, now: appDiagnosticNow())
            .first(where: { $0.routes == routes }) else { return false }
        var wrote = false
        await performSerializedPairedMacWrite {
            guard await self.isScopeCurrent(scope),
                  self.tailscaleSuggestionCache.groups(for: key, scope: scope, now: self.appDiagnosticNow())
                    .contains(group) else { return }
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
