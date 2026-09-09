public import CMUXMobileCore
public import CmuxMobilePairedMac
import Foundation

@MainActor
extension MobileShellComposite {
    /// Route identity for teardown follows the same kind-and-endpoint rules
    /// used by persisted route removal. A refreshed route can reuse an id for
    /// another endpoint, so the endpoint must be part of the match.
    private func routeMatchesForRemoval(
        _ removed: CmxAttachRoute,
        _ live: CmxAttachRoute
    ) -> Bool {
        removed.kind == live.kind && removed.endpoint == live.endpoint
    }

    /// Retire any live session that is using the route after the persistent
    /// removal succeeds. The pairing key is exact, so deleting one tagged
    /// build cannot disconnect its Stable/Nightly sibling on the same Mac.
    private func disconnectLiveRouteIfNeeded(
        _ removedRoute: CmxAttachRoute,
        ownerKey: MacPairingKey
    ) async {
        let focused = connections[ownerKey.pairingID]
        let foregroundClient = focused?.client ?? remoteClient
        let recoveryKey = foregroundMacDeviceID == nil
            ? recoveryTargetMacDeviceID.map {
                MacPairingKey(
                    macDeviceID: $0,
                    instanceTag: recoveryTargetInstanceTag
                )
            }
            : nil
        let foregroundAttemptKey = recoveryKey ?? foregroundMacKey
        let matchesForegroundAttempt = foregroundAttemptKey == ownerKey
            && activeRoute.map {
                routeMatchesForRemoval(removedRoute, $0)
            } == true
        let isForegroundRoute = connectionState == .connected
            && foregroundMacKey == ownerKey
            && (activeRoute.map {
                routeMatchesForRemoval(removedRoute, $0)
            } == true || focused.map {
                routeMatchesForRemoval(removedRoute, $0.route)
            } == true)

        if matchesForegroundAttempt || isForegroundRoute {
            if matchesForegroundAttempt {
                // A reconnect publishes its candidate route before the dial
                // starts. Supersede that exact attempt even while the shell is
                // still disconnected, otherwise it can finish on the deleted
                // endpoint.
                storedMacReconnectGeneration &+= 1
                isReconnectingStoredMac = false
                pendingForcedStoredMacReconnect = false
                didFinishStoredMacReconnectAttempt = true
                connectionAttemptGeneration = UUID()
            }
            // `clearRemoteConnectionContext` historically looked up the
            // foreground registry entry by bare device id. Remove the exact
            // tagged entry first so the live registry cannot retain a client
            // after this route is deleted.
            if let focused {
                removeControlCapability(ifMatching: focused)
                removeFocusedConnection(ifMatching: focused)
            }
            disconnectLiveConnection(preservingOtherMacWorkspaceState: true)
            await foregroundClient?.disconnectAndWaitForTransportDrain()
            return
        }

        if let focused,
           routeMatchesForRemoval(removedRoute, focused.route) {
            removeFocusedConnection(ifMatching: focused)
            focused.client.retire()
            await focused.client.disconnectAndWaitForTransportDrain()
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

        guard let removedRouteIndex = mac.routes.firstIndex(where: {
            routeMatchesForRemoval(route, $0)
        }) else { return false }
        let removedRoute = mac.routes[removedRouteIndex]
        var routes = mac.routes
        routes.remove(at: removedRouteIndex)
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
                    route: removedRoute,
                    condition: .matchingInstanceTag(mac.instanceTag),
                    stackUserID: mac.stackUserID ?? scope.userID,
                    teamID: mac.teamID,
                    now: Date()
                )
                guard wrote else { return false }
            }
            guard await isScopeCurrent(scope) else { return false }
            await disconnectLiveRouteIfNeeded(
                removedRoute,
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
