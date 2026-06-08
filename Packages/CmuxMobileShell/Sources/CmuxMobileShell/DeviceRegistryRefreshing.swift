public import CMUXMobileCore

/// A best-effort lookup of fresher attach routes for a paired Mac from the
/// team-scoped device registry.
///
/// The registry is a rendezvous layer, not an authority: it lets a re-launched
/// phone discover the current routes for the Mac it last paired with (e.g. when
/// the Mac moved networks or restarted on a different port). It is deliberately
/// fallible — a `nil` result means "registry unavailable, use what you have," so
/// reconnect always falls back to the locally persisted paired-Mac routes and
/// pairing survives the cloud registry being down.
public protocol DeviceRegistryRefreshing: Sendable {
    /// Fetch the registry's current routes for the given Mac device id, scoped to
    /// the signed-in user's team.
    ///
    /// - Returns: The registry's routes for that Mac, or `nil` when the registry
    ///   is unreachable, the call is unauthorized, or the Mac is not registered.
    ///   `nil` and `[]` are both treated as "no fresher routes" by
    ///   ``DeviceRegistryRouteSelection/selectReconnectRoutes(local:registry:)``.
    func freshRoutes(forMacDeviceID macDeviceID: String) async -> [CmxAttachRoute]?
}

/// Pure route-selection policy for reconnect, isolated so it is unit-testable
/// without any network or store. The reconnect path connects on `local` routes
/// immediately (no added latency on the common case) and only *replaces* the
/// persisted routes when the registry returns a usable, different set.
public enum DeviceRegistryRouteSelection {
    /// Choose the routes to persist for the next reconnect.
    ///
    /// - Parameters:
    ///   - local: The routes currently persisted for the paired Mac.
    ///   - registry: The registry's routes, or `nil` when it was unavailable.
    /// - Returns: The registry routes when they are non-empty and differ from
    ///   `local` (so a stale-route Mac gets rescued on the next reconnect
    ///   trigger); otherwise `local`, so an unavailable or no-op registry never
    ///   discards working routes. The result is `nil` only to signal "no change
    ///   needed," letting callers skip a redundant store write.
    public static func selectReconnectRoutes(
        local: [CmxAttachRoute],
        registry: [CmxAttachRoute]?
    ) -> [CmxAttachRoute]? {
        guard let registry, !registry.isEmpty else { return nil }
        guard registry != local else { return nil }
        return registry
    }

    /// Whether a background registry refresh may write back into the paired-Mac
    /// store, re-evaluated *after* the network call.
    ///
    /// The refresh upserts with `markActive: true`, so it must not resurrect a
    /// pairing that the user removed or deactivated while the network call was in
    /// flight. It is safe to apply only when the same user is still signed in and
    /// the Mac it refreshed is still the active paired Mac. If the user signed
    /// out, switched accounts, forgot the Mac, or switched to a different active
    /// Mac, the captured user no longer matches, or the active Mac id is now
    /// `nil`/different, so the write is rejected.
    ///
    /// - Parameters:
    ///   - isSignedIn: Whether a user is signed in now.
    ///   - capturedUserID: The signed-in user when the refresh started.
    ///   - currentUserID: The signed-in user now.
    ///   - activeMacID: The still-active paired Mac id now, or `nil` if none.
    ///   - targetMacID: The Mac id this refresh fetched routes for.
    public static func shouldApplyRegistryRefresh(
        isSignedIn: Bool,
        capturedUserID: String?,
        currentUserID: String?,
        activeMacID: String?,
        targetMacID: String
    ) -> Bool {
        guard isSignedIn else { return false }
        guard capturedUserID == currentUserID else { return false }
        return activeMacID == targetMacID
    }
}
