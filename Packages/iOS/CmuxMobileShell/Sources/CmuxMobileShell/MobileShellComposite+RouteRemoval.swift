public import CMUXMobileCore
public import CmuxMobilePairedMac
import Foundation

@MainActor
extension MobileShellComposite {
    /// Route identity for teardown must follow the same id-or-endpoint rules
    /// used when a refreshed route replaces an older route record. The kind is
    /// part of the identity so a Tailscale route cannot retire a different
    /// transport that happens to use the same host and port.
    private func routeMatchesForRemoval(
        _ removed: CmxAttachRoute,
        _ live: CmxAttachRoute
    ) -> Bool {
        removed.kind == live.kind
            && (removed.id == live.id || removed.endpoint == live.endpoint)
    }

    /// Retire any live session that is using the route after the persistent
    /// removal succeeds. The pairing key is exact, so deleting one tagged
    /// build cannot disconnect its Stable/Nightly sibling on the same Mac.
    private func disconnectLiveRouteIfNeeded(
        _ removedRoute: CmxAttachRoute,
        ownerKey: MacPairingKey
    ) {
        let focused = connections[ownerKey.pairingID]
        let isForegroundRoute = connectionState == .connected
            && foregroundMacKey == ownerKey
            && (activeRoute.map {
                routeMatchesForRemoval(removedRoute, $0)
            } == true || focused.map {
                routeMatchesForRemoval(removedRoute, $0.route)
            } == true)

        if isForegroundRoute {
            // `clearRemoteConnectionContext` historically looked up the
            // foreground registry entry by bare device id. Remove the exact
            // tagged entry first so the live registry cannot retain a client
            // after this route is deleted.
            if let focused {
                removeControlCapability(ifMatching: focused)
                removeFocusedConnection(ifMatching: focused)
            }
            disconnectLiveConnection(preservingOtherMacWorkspaceState: true)
            return
        }

        if let focused,
           routeMatchesForRemoval(removedRoute, focused.route) {
            removeFocusedConnection(ifMatching: focused)
            focused.client.retire()
            Task { await focused.client.disconnect() }
            markSecondaryMacUnavailable(ownerKey)
        }

        if let subscription = secondaryMacSubscriptions[ownerKey],
           routeMatchesForRemoval(removedRoute, subscription.route) {
            cancelSecondaryControlReassertion(ifOwnedBy: subscription)
            subscription.cancel()
            secondaryMacSubscriptions[ownerKey] = nil
            markSecondaryMacUnavailableIfUnowned(ownerKey)
        }
    }

    /// Removes one user-controlled route from one exact Mac/build pairing.
    /// Iroh is the permanent identity route and cannot be removed.
    @discardableResult
    public func removeRoute(
        _ route: CmxAttachRoute,
        macDeviceID: String,
        instanceTag: String?,
        deleteComputerIfLastRoute: Bool = false
    ) async -> Bool {
        guard route.kind != .iroh,
              let scope = await currentScopeSnapshot(),
              let pairedMacStore,
              let mac = pairedMacsForIdentityMatching.first(where: {
                  $0.macDeviceID == macDeviceID && $0.instanceTag == instanceTag
              }) else { return false }

        let routes = mac.routes.filter { $0.id != route.id }
        guard routes.count != mac.routes.count else { return false }
        do {
            if routes.isEmpty {
                guard deleteComputerIfLastRoute else { return false }
                try await pairedMacStore.removeExactScope(
                    macDeviceID: mac.macDeviceID,
                    instanceTag: mac.instanceTag,
                    stackUserID: mac.stackUserID ?? scope.userID,
                    teamID: mac.teamID
                )
            } else {
                let wrote = try await pairedMacStore.removeRouteIfAuthorized(
                    macDeviceID: mac.macDeviceID,
                    route: route,
                    condition: .matchingInstanceTag(mac.instanceTag),
                    stackUserID: mac.stackUserID ?? scope.userID,
                    teamID: mac.teamID,
                    now: Date()
                )
                guard wrote else { return false }
            }
            guard await isScopeCurrent(scope) else { return false }
            disconnectLiveRouteIfNeeded(
                route,
                ownerKey: MacPairingKey(
                    macDeviceID: mac.macDeviceID,
                    instanceTag: mac.instanceTag
                )
            )
            await loadPairedMacs()
            await loadRegistryDevices()
            return true
        } catch {
            // Keep the authoritative row unchanged when the scoped write fails.
            return false
        }
    }
}
